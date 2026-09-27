#!/usr/bin/perl -w

=head1 NAME

Alien::Package::Pacman - an object that represents a pacman package

=cut

package Alien::Package::Pacman;
use strict;
use base qw(Alien::Package);
use File::Basename;

=head1 DESCRIPTION

This is an object class that represents a pacman package (.pkg.tar.zst).
It is derived from Alien::Package.

=head1 FIELDS

=over 4

=item compression

Compression type for the output package (zst, xz, gz, lz4, lzo).
Defaults to zst (modern Arch standard).

=back

=head1 METHODS

=over 4

=item init

Set default compression.

=cut

sub init {
	my $this=shift;
	$this->SUPER::init(@_);
	$this->{compression}='zst';
}

=item checkfile

Detect pacman package files by their extension.

=cut

sub checkfile {
	my ($this, $file) = @_;
	return $file =~ m/\.pkg\.tar\.(?:zst|xz|gz|bz2|lz4|lzo)$/i;
}

=item install

Install a pacman package with pacman -U.

=cut

sub install {
	my ($this, $pkg) = @_;

	my $v=$Alien::Package::verbose;
	$Alien::Package::verbose=2;
	$this->do("pacman", "-U", "--noconfirm", $pkg)
		or die "Unable to install";
	$Alien::Package::verbose=$v;
}

=item scan

Scan a pacman package for metadata by reading .PKGINFO.

=cut

sub scan {
	my $this=shift;
	$this->SUPER::scan(@_);
	my $file=$this->filename;

	# Read .PKGINFO from the package.
	my $pkginfo=$this->_read_pkg_member('.PKGINFO');
	die "Could not read .PKGINFO from $file"
		if ! defined $pkginfo || $pkginfo !~ /\S/;

	my %info;
	foreach my $line (split /\n/, $pkginfo) {
		if ($line =~ /^(\w+)\s*=\s*(.*)$/) {
			push @{$info{$1}}, $2;
		}
	}

	# Basic fields.
	if ($info{pkgname} && $info{pkgname}->[0] =~ /^(.+?)-([^-]+)$/) {
		$this->name($1);
		$this->version($2);
	}
	elsif ($info{pkgname}) {
		$this->name($info{pkgname}->[0]);
		$this->version(1);
	}
	if ($info{pkgver}) {
		# pkgver = version-pkgrel
		if ($info{pkgver}->[0] =~ /^(.+?)-([^-]+)$/) {
			$this->version($1);
			$this->release($2);
		}
		else {
			$this->version($info{pkgver}->[0]);
			$this->release(1);
		}
	}
	$this->arch($info{arch}->[0]) if $info{arch};
	$this->summary($info{pkgdesc}->[0]) if $info{pkgdesc};
	$this->description($info{pkgdesc}->[0]) if $info{pkgdesc};
	$this->copyright(join(", ", @{$info{license}})) if $info{license};
	$this->depends(join(", ", @{$info{depends}})) if $info{depends};
	$this->group("unknown");
	$this->distribution("Arch Linux");
	$this->origformat("pacman");
	$this->changelogtext('');
	$this->usescripts(1);

	# Conffiles from 'backup' entries.
	my @conffiles;
	if ($info{backup}) {
		foreach my $f (@{$info{backup}}) {
			$f =~ s|^/||;
			push @conffiles, "/$f";
		}
	}
	$this->conffiles(\@conffiles);

	# File list (exclude metadata files).
	my @filelist;
	foreach my $f ($this->_list_pkg_files()) {
		chomp $f;
		next if $f eq '' || $f =~ /^\./;
		$f =~ s:^\./::;
		push @filelist, "/$f";
	}
	$this->filelist(\@filelist);

	# Scripts from .INSTALL.
	my $install_script=$this->_read_pkg_member('.INSTALL');
	if (defined $install_script && $install_script =~ /\S/) {
		$this->_parse_install_script($install_script);
	}

	$this->binary_info(scalar $this->runpipe(0, "ls -l '" . _shell_quote($file) . "'"));

	return 1;
}

=item _read_pkg_member

Read a single member from the package archive.
Tries bsdtar first (handles zst natively), then tar.

=cut

# Shell-quote a string for safe use in single-quoted shell context.
# Replaces ' with '\'' (close quote, escaped quote, reopen quote).
sub _shell_quote {
	my $s=shift;
	$s =~ s/'/'\\''/g;
	return $s;
}

sub _read_pkg_member {
	my ($this, $member) = @_;
	my $file=_shell_quote($this->filename);

	my $content=$this->runpipe(1, "bsdtar -xOf '$file' '$member' 2>/dev/null");
	return $content if defined $content && $content =~ /\S/;

	# Fallback with tar (works for xz, gz, bz2 but not zst without zstd support)
	$content=$this->runpipe(1, "tar -xOf '$file' '$member' 2>/dev/null");
	return $content if defined $content && $content =~ /\S/;

	return;
}

=item _list_pkg_files

List all files in the package archive.

=cut

sub _list_pkg_files {
	my $this=shift;
	my $file=_shell_quote($this->filename);

	my @files=$this->runpipe(1, "bsdtar -tf '$file' 2>/dev/null");
	return @files if @files;

	@files=$this->runpipe(1, "tar -tf '$file' 2>/dev/null");
	return @files;
}

=item _parse_install_script

Parse the unified .INSTALL script into individual script fields.
Pacman install scripts use shell functions:
  pre_install() { ... }
  post_install() { ... }
  pre_remove() { ... }
  post_remove() { ... }
  pre_upgrade() { ... }
  post_upgrade() { ... }

=cut

sub _parse_install_script {
	my ($this, $script) = @_;

	# Map pacman script functions to internal (base class) field names.
	my %funcmap=(
		pre_install  => 'preinst',
		post_install => 'postinst',
		pre_upgrade  => 'preinst',
		post_upgrade => 'postinst',
		pre_remove   => 'prerm',
		post_remove  => 'postrm',
	);

	foreach my $func (keys %funcmap) {
		if ($script =~ /^\s*$func\s*\(\)\s*\{/m) {
			# Extract function body up to closing brace at start of line.
			my ($body) = $script =~ /^\s*$func\s*\(\)\s*\{\s*\n(.*?)^\}/ms;
			if (defined $body && $body =~ /\S/) {
				$body =~ s/^\s+//;
				$body =~ s/\s+$//;
				my $method=$funcmap{$func};
				$this->$method($body);
			}
		}
	}
}

=item unpack

Unpack a pacman package into the working directory.

=cut

sub unpack {
	my $this=shift;
	$this->SUPER::unpack(@_);
	my $file=$this->filename;
	my $workdir=$this->unpacked_tree;

	# Extract everything except metadata files.
	my $ok=$this->do("bsdtar", "-xf", $file, "-C", $workdir,
	                 "--exclude=.PKGINFO", "--exclude=.INSTALL",
	                 "--exclude=.MTREE", "--exclude=.BUILDINFO");
	if (! $ok) {
		$ok=$this->do("tar", "-xf", $file, "-C", $workdir,
		              "--exclude=.PKGINFO", "--exclude=.INSTALL",
		              "--exclude=.MTREE", "--exclude=.BUILDINFO");
	}
	die "Unpacking of '$file' failed: $!" if ! $ok;

	return 1;
}

=item prep

Prepare the build tree by generating PKGBUILD and .INSTALL.

=cut

sub prep {
	my $this=shift;
	my $dir=$this->unpacked_tree || die "The package must be unpacked first!";

	# Generate .INSTALL first so we know if scripts exist.
	my $has_install_script=0;
	if ($this->usescripts) {
		my $install_script=$this->_generate_install_script();
		if ($install_script =~ /\S/) {
			open(my $fh, '>', "$dir/.INSTALL") or die "Cannot write $dir/.INSTALL: $!";
			print $fh $install_script;
			close $fh;
			$has_install_script=1;
		}
	}

	# Generate PKGBUILD (reference .INSTALL if it exists).
	my $pkgbuild=$this->_generate_pkgbuild($has_install_script);
	open(my $fh, '>', "$dir/PKGBUILD") or die "Cannot write $dir/PKGBUILD: $!";
	print $fh $pkgbuild;
	close $fh;

	return 1;
}

=item _generate_pkgbuild

Generate PKGBUILD content for the package.

=cut

sub _generate_pkgbuild {
	my $this=shift;
	my $has_install_script=shift || 0;

	my $name=$this->name;
	my $version=$this->version;
	my $release=$this->release;
	my $arch=$this->arch;
	# Use description for pkgdesc (user can override with --description).
	# Fall back to summary, then to a default.
	my $pkgdesc=$this->description || $this->summary || "Converted package";
	# pkgdesc must be a single line.
	$pkgdesc=(split /\n/, $pkgdesc)[0];
	$pkgdesc =~ s/^\s+|\s+$//g;
	$pkgdesc="Converted package" if $pkgdesc eq '';
	my $summary=$pkgdesc;
	my $description=$this->description || $summary;
	my $license=$this->copyright || "unknown";
	my $depends=$this->depends || "";
	my $url="";

	# Sanitize for PKGBUILD (double-quoted strings).
	# Escape ALL shell metacharacters to prevent command injection
	# (PKGBUILD is sourced as a shell script by makepkg).
	$summary =~ s/([\\"`\$!\n])/\\$1/g;
	$summary =~ s/\n/ /g;
	$description =~ s/([\\"`\$!\n])/\\$1/g;
	$description =~ s/\n/ /g;
	$license =~ s/([\\"`\$!\n])/\\$1/g;
	$license =~ s/\n/ /g;

	# Sanitize pkgname and pkgver (must be valid shell identifiers).
	# pkgname: only alphanumeric, dashes, underscores, dots
	$name =~ s/[^a-zA-Z0-9._-]/-/g;
	# pkgver: only alphanumeric, dashes, underscores, dots, colons, plus, tilde
	$version =~ s/[^a-zA-Z0-9._+~:-]/-/g;
	# pkgrel: only alphanumeric and dots
	$release =~ s/[^a-zA-Z0-9.]/-/g;

	# Format depends array.
	# Sanitize: remove single quotes and newlines (would break shell quoting).
	my $depends_array="()";
	if ($depends && $depends =~ /\S/) {
		my @deps=split /\s*,\s*/, $depends;
		@deps=map { s/['"\n]//g; $_ } @deps;
		$depends_array="(" . join(" ", map { "'$_'" } @deps) . ")";
	}

	# Format backup (conffiles) array.
	# Sanitize: remove single quotes and newlines.
	my $backup_array="()";
	my @conffiles=@{$this->conffiles || []};
	if (@conffiles) {
		my @backup=map { my $b=$_; $b =~ s|^/||; $b =~ s/['"\n]//g; $b } @conffiles;
		$backup_array="(" . join(" ", map { "'$_'" } @backup) . ")";
	}

	my $compression=$this->{compression} || 'zst';
	my $pkg_ext=".pkg.tar.$compression";

	my $install_line = $has_install_script ? "install=.INSTALL" : "";

	return <<"EOF";
# Generated by alien $Alien::Version
pkgname='$name'
pkgver=$version
pkgrel=$release
pkgdesc="$summary"
arch=('$arch')
url="$url"
license=('$license')
depends=$depends_array
backup=$backup_array
options=(!strip !emptydirs)
$install_line
PKGEXT="$pkg_ext"

package() {
	cd "\$startdir"
	# Copy all files from the package tree into the package directory.
	find . -mindepth 1 -maxdepth 1 ! -name 'PKGBUILD' ! -name '.INSTALL' ! -name '.PKGINFO' ! -name '.MTREE' ! -name '.BUILDINFO' ! -name 'pkg' ! -name 'src' -exec cp -a {} "\$pkgdir/" \\;
}
EOF
}

=item _generate_install_script

Generate .INSTALL script content from individual script fields.

=cut

sub _generate_install_script {
	my $this=shift;
	my @parts;

	# Map internal (base class) script fields to pacman .INSTALL functions.
	my %scriptmap=(
		preinst  => 'pre_install',
		postinst => 'post_install',
		prerm    => 'pre_remove',
		postrm   => 'post_remove',
	);

	foreach my $base (qw(preinst postinst prerm postrm)) {
		my $content=$this->$base();
		if (defined $content && $content =~ /\S/) {
			$content =~ s/^\s+//;
			$content =~ s/\s+$//;
			# Strip shebang line (pacman .INSTALL functions don't use shebangs).
			$content =~ s/^#!.*\n?//;
			$content =~ s/^\s+//;
			$content =~ s/\s+$//;
			next if $content eq '';
			push @parts, "$scriptmap{$base}() {\n$content\n}";
		}
	}

	return join("\n\n", @parts) . "\n";
}

=item build

Build a pacman package. Tries makepkg first (preferred), falls back
to manual tar-based packaging if makepkg is not available.

=cut

sub build {
	my $this=shift;
	my $dir=$this->unpacked_tree || die "The package must be unpacked first!";

	my $name=$this->name;
	my $version=$this->version;
	my $release=$this->release;
	my $arch=$this->arch;
	my $compression=$this->{compression} || 'zst';
	my $pkg_file="$name-$version-$release-$arch.pkg.tar.$compression";

	# Try makepkg first (preferred).
	if ($this->_inpath('makepkg')) {
		my $v=$Alien::Package::verbose;
		$Alien::Package::verbose=2;

		my $dir_q=_shell_quote($dir);

		# makepkg refuses to run as root, use fakeroot.
		my $cmd;
		if ($> == 0) {
			if ($this->_inpath('fakeroot')) {
				$cmd="cd '$dir_q' && fakeroot makepkg --noconfirm --noprogressbar --skippgpcheck 2>&1";
			}
			else {
				# makepkg needs a non-root user or fakeroot.
				# Fall back to manual build.
				$Alien::Package::verbose=$v;
				return $this->_build_manual($dir, $pkg_file);
			}
		}
		else {
			$cmd="cd '$dir_q' && makepkg --noconfirm --noprogressbar --skippgpcheck 2>&1";
		}

		my $log=$this->runpipe(1, $cmd);
		if ($?) {
			# makepkg failed, try manual build.
			$Alien::Package::verbose=$v;
			return $this->_build_manual($dir, $pkg_file);
		}
		$Alien::Package::verbose=$v;

		# Find the generated package and move it to the current directory.
		my @pkgs=glob("$dir/*.pkg.tar.*");
		if (@pkgs) {
			my $built=$pkgs[0];
			$this->do("mv", $built, "$pkg_file");
			return $pkg_file;
		}
	}

	# Fallback: manual package creation.
	return $this->_build_manual($dir, $pkg_file);
}

=item _build_manual

Create the package manually without makepkg.
Generates .PKGINFO, .MTREE, .BUILDINFO, and archives them.

=cut

sub _build_manual {
	my ($this, $dir, $pkg_file) = @_;

	# Shell-quote for safe use in shell commands.
	my $dir_q=_shell_quote($dir);
	my $output_q=_shell_quote("../$pkg_file");

	# Create .PKGINFO.
	my $pkginfo=$this->_generate_pkginfo();
	open(my $fh, '>', "$dir/.PKGINFO") or die "Cannot write $dir/.PKGINFO: $!";
	print $fh $pkginfo;
	close $fh;

	# Create .MTREE (basic file manifest).
	$this->do("cd '$dir_q' && bsdtar --format=mtree -cf .MTREE --options='!all,use-set,type,uid,gid,mode,time,size,md5,sha256' . 2>/dev/null");

	# Create .BUILDINFO (minimal).
	my $buildinfo=$this->_generate_buildinfo();
	open($fh, '>', "$dir/.BUILDINFO") or die "Cannot write $dir/.BUILDINFO: $!";
	print $fh $buildinfo;
	close $fh;

	# Determine compression program.
	my $compression=$this->{compression} || 'zst';
	my $comp_prog = $compression eq 'zst' ? 'zstd -c -T0' :
	                $compression eq 'xz'  ? 'xz -c -T0' :
	                $compression eq 'gz'  ? 'gzip -c' :
	                $compression eq 'lz4' ? 'lz4 -c' :
	                $compression eq 'lzo' ? 'lzop -c' :
	                'zstd -c -T0';

	# Build the package archive.
	# Order matters: .PKGINFO first, then .INSTALL, then .MTREE, .BUILDINFO, then files.
	my $cmd="cd '$dir_q' && bsdtar --format=ustar -cf - .PKGINFO .INSTALL .MTREE .BUILDINFO * 2>/dev/null | $comp_prog > '$output_q'";
	if (! $this->do($cmd)) {
		# Try tar if bsdtar is not available.
		$cmd="cd '$dir_q' && tar --format=ustar -cf - .PKGINFO .INSTALL .MTREE .BUILDINFO * 2>/dev/null | $comp_prog > '$output_q'";
		$this->do($cmd) or die "Manual pacman package build failed";
	}

	return $pkg_file;
}

=item _generate_pkginfo

Generate .PKGINFO content.

=cut

sub _generate_pkginfo {
	my $this=shift;

	my $name=$this->name;
	my $version=$this->version;
	my $release=$this->release;
	my $arch=$this->arch;
	# Use description for pkgdesc (user can override with --description).
	my $summary=$this->description || $this->summary || "Converted package";
	$summary=(split /\n/, $summary)[0];
	$summary =~ s/^\s+|\s+$//g;
	$summary="Converted package" if $summary eq '';
	my $description=$this->description || $summary;
	my $license=$this->copyright || "unknown";
	my $depends=$this->depends || "";
	my @conffiles=@{$this->conffiles || []};

	my $date=time();

	# Sanitize: strip newlines and null bytes from all values
	# (prevents injection of fake .PKGINFO entries).
	$name =~ s/[\n\r\x00]/ /g;
	$version =~ s/[\n\r\x00]/ /g;
	$release =~ s/[\n\r\x00]/ /g;
	$arch =~ s/[\n\r\x00]/ /g;
	$summary =~ s/[\n\r\x00]/ /g;
	$license =~ s/[\n\r\x00]/ /g;

	my $pkginfo=<<"EOF";
# Generated by alien $Alien::Version
pkgname = $name
pkgver = $version-$release
pkgdesc = $summary
arch = $arch
builddate = $date
packager = Alien Package Converter
license = $license
EOF

	# Dependencies (strip newlines to prevent .PKGINFO injection).
	if ($depends && $depends =~ /\S/) {
		foreach my $dep (split /\s*,\s*/, $depends) {
			$dep =~ s/[\n\r\x00]/ /g;
			$dep =~ s/^\s+|\s+$//g;
			next if $dep eq '';
			$pkginfo .= "depend = $dep\n";
		}
	}

	# Backup (conffiles) — strip newlines and null bytes.
	foreach my $cf (@conffiles) {
		$cf =~ s|^/||;
		$cf =~ s/[\n\r\x00]/ /g;
		$cf =~ s/^\s+|\s+$//g;
		next if $cf eq '';
		$pkginfo .= "backup = $cf\n";
	}

	return $pkginfo;
}

=item _generate_buildinfo

Generate minimal .BUILDINFO.

=cut

sub _generate_buildinfo {
	my $this=shift;

	return <<"EOF";
format = 2
pkgname = @{[$this->name]}
pkgver = @{[$this->version]}-@{[$this->release]}
pkgarch = @{[$this->arch]}
builddate = @{[time()]}
buildenv = !distcc
buildenv = !color
buildenv = !ccache
buildenv = !check
buildtool = alien $Alien::Version
buildtoolver = $Alien::Version
EOF
}

=item cleantree

Clean up generated files from the build tree.

=cut

sub cleantree {
	my $this=shift;
	my $dir=$this->unpacked_tree || return;

	foreach my $f (qw(PKGBUILD .INSTALL .PKGINFO .MTREE .BUILDINFO)) {
		unlink "$dir/$f";
	}
}

=item compression

Set/get the compression type for the output package.

=cut

sub compression {
	my $this=shift;
	$this->{compression}=shift if @_;
	return $this->{compression};
}

=item arch

Set/get architecture, translating between pacman and internal formats.

=cut

sub arch {
	my $this=shift;

	# Set: translate from pacman format to internal (debian-style).
	if (@_) {
		my $arch=shift;
		$arch='amd64' if $arch eq 'x86_64';
		$arch='arm64' if $arch eq 'aarch64';
		$arch='i386' if $arch eq 'i686';
		$arch='armel' if $arch eq 'armv7h';
		$arch='all' if $arch eq 'any';
		$this->{arch}=$arch;
	}

	# Get: translate from internal (debian-style) to pacman format.
	my $arch=$this->{arch};
	if ($arch eq 'amd64') { $arch='x86_64'; }
	elsif ($arch eq 'arm64') { $arch='aarch64'; }
	elsif ($arch eq 'i386') { $arch='i686'; }
	elsif ($arch eq 'armel') { $arch='armv7h'; }
	elsif ($arch eq 'all') { $arch='any'; }
	return $arch;
}

=item name

Set/get package name. Sanitized for safe use in filesystem
paths and shell commands.

=cut

sub name {
	my $this=shift;

	# Set.
	$this->{name}=shift if @_;

	return unless defined wantarray;

	# Get: sanitize (alphanumeric, dots, underscores, dashes only).
	my $name=$this->{name};
	$name =~ s/[^a-zA-Z0-9._-]/-/g;
	$name =~ s/^-+|-+$//g; # strip leading/trailing dashes
	$name='unknown' if $name eq '';
	return $name;
}

=item version

Set/get version. Pacman uses pkgver-pkgrel format.
Sanitized for safe use in filesystem paths and shell commands.

=cut

sub version {
	my $this=shift;

	# Set: handle version-release format.
	if (@_) {
		my $version=shift;
		if ($version =~ /(.+)-([^-]+)/) {
			$this->{version}=$1;
			$this->{release}=$2;
		}
		else {
			$this->{version}=$version;
			$this->{release}=1 unless defined $this->{release};
		}
	}

	return unless defined wantarray;

	# Get: sanitize (alphanumeric, dots, dashes, colons, plus, tilde).
	my $version=$this->{version};
	$version =~ s/[^a-zA-Z0-9._+~:-]/-/g;
	$version='0' if $version eq '';
	return $version;
}

=item _inpath

Check if a program is in PATH.

=cut

sub _inpath {
	my ($this, $program) = @_;
	foreach (split(/:/, $ENV{PATH})) {
		return 1 if -x "$_/$program";
	}
	return '';
}

=back

=head1 AUTHOR

Pacman support added for alien package converter.

=cut

1
