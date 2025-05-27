#!/usr/bin/perl -w

=head1 NAME

Alien::Package::Tgz - an object that represents a tgz package

=cut

package Alien::Package::Tgz;
use strict;
use base qw(Alien::Package);
use Cwd qw(abs_path);
use Alien::Package::Rpm qw(arch);

my $tarext=qr/\.(?:tgz|tar(?:\.(?:gz|Z|z|bz|bz2))?|taz)$/;

=head1 DESCRIPTION

This is an object class that represents a tgz package, as used in Slackware. 
It also allows conversion of raw tar files.
It is derived from Alien::Package.

=head1 CLASS DATA

=over 4

=item scripttrans

Translation table between canoical script names and the names used in
tgz's.

=cut

use constant scripttrans => {
		postinst => 'doinst.sh',
		postrm => 'delete.sh',
		prerm => 'predelete.sh',
		preinst => 'predoinst.sh',
	};

=back

=head1 METHODS

=over 4

=item checkfile

Detect tgz files by their extension.

=cut

sub checkfile {
        my $this=shift;
        my $file=shift;

        return $file =~ m/$tarext$/;
}

=item install

Install a tgz with installpkg. Pass in the filename of the tgz to install.

installpkg (a slackware program) is used because I'm not sanguine about
just untarring a tgz file. It might trash a system.

=cut

sub install {
	my $this=shift;
	my $tgz=shift;

	if (-x "/sbin/installpkg") {
		my $v=$Alien::Package::verbose;
		$Alien::Package::verbose=2;
		$this->do("/sbin/installpkg", "$tgz")
			or die "Unable to install";
		$Alien::Package::verbose=$v;
	}
	else {
		die "Sorry, I cannot install the generated .tgz file because /sbin/installpkg is not present. You can use tar to install it yourself.\n"
	}
}

=item scan

Scan a tgz file for fields. Has to scan the filename for most of the
information, since there is little useful metadata in the file itself.

=cut

sub scan {
	my $this=shift;
	$this->SUPER::scan(@_);
	my $file=$this->filename;

	# Get basename of the filename.
	my ($basename)=('/'.$file)=~m#^/?.*/(.*?)$#;

	# Strip out any tar extensions.
	$basename=~s/$tarext//;

	if ($basename=~m/([\w-]+)-([0-9\.?]+).*/) {
		$this->name($1);
		$this->version($2);
	}
	else {
		$this->name($basename);
		$this->version(1);
	}

	$this->arch('all');

	# Attempt to extract slack-desc
	my $slack_desc_content = $this->runpipe(1, "tar Oxf '$file' install/slack-desc 2>/dev/null");
	my $pkg_name = $this->name(); # Get package name early

	if ($slack_desc_content && $slack_desc_content =~ /\S/) {
		my @slack_lines = split /\n/, $slack_desc_content;
		
		# Default values if parsing fails or parts are missing
		my $default_summary_text = "Package from tgz file (slack-desc found)";
		my $default_description_text = "Package from tgz file (slack-desc found)";
		$this->summary($default_summary_text);
		$this->description($default_description_text);

		my $summary_parsed_successfully = 0;

		if (@slack_lines) {
			my $first_line = $slack_lines[0]; # Peek at first line
			# Try to parse summary from the first line using the strict format
			if ($first_line =~ /^\Q$pkg_name\E: \Q$pkg_name\E \((.+)\)\s*$/) {
				my $summary_candidate = $1;
				if ($summary_candidate =~ /\S/) { # Check if captured summary is not just whitespace
					$this->summary($summary_candidate);
					$this->description($summary_candidate); # Initial guess for description
					shift @slack_lines; # Consume the line as it was successfully parsed
					$summary_parsed_successfully = 1;
				}
			}
		}
		
		# Description Parsing from remaining lines (or all lines if summary parse failed)
		my @description_parts;
		my $expected_prefix_regex = qr/^\Q$pkg_name\E: /; # $pkg_name: <text>
		my $paragraph_break_regex = qr/^\Q$pkg_name\E:$/;  # $pkg_name:

		foreach my $line (@slack_lines) {
			if ($line =~ $paragraph_break_regex) {
				push @description_parts, ""; # Paragraph break
			} elsif ((my $desc_content = $line) =~ s/$expected_prefix_regex//) {
				# Prefix was stripped, $desc_content now holds the rest
				push @description_parts, $desc_content;
			} else {
				# Line does not match strict format, ignore it for description.
				# This handles cases where the first line was not a valid summary
				# and is now being re-evaluated here but doesn't fit description format either.
			}
		}

		if (@description_parts) {
			my $parsed_description = join("\n", @description_parts);
			# Remove leading/trailing empty lines from the final description block
			$parsed_description =~ s/^\n+//;
			$parsed_description =~ s/\n+$/\n/; # Keep single trailing newline if content, or make it one if many
            $parsed_description =~ s/\s+$//; # Trim trailing whitespace overall, including last newline if it was just that

			if ($parsed_description =~ /\S/) {
				$this->description($parsed_description);
				# If summary is still the generic default, but we have a description,
				# try to set summary from the first line of this description.
				if ($this->summary() eq $default_summary_text) {
					my ($first_desc_line) = split /\n/, $parsed_description;
					if ($first_desc_line && length($first_desc_line) < 100 && $first_desc_line =~ /\S/) {
						$this->summary($first_desc_line);
					}
				}
			} else {
			    # Description parts were found but resulted in an empty string (e.g. only paragraph markers)
			    # Revert to summary if summary was good, or default if summary was also default.
			    if ($summary_parsed_successfully) {
			        $this->description($this->summary());
			    } else {
			        $this->description($default_description_text); # Keep default
			    }
			}
		} elsif (!$summary_parsed_successfully) {
            # No description parts AND summary was not parsed successfully means slack-desc was
            # present but entirely unparsable or empty after the first line (if any).
            # Summary and Description remain $default_summary_text.
        }
        # If summary was parsed but no description lines, description is already set to summary.

	} else {
		# Original behavior if slack-desc is not found or empty
		$this->summary("Converted tgz package");
		$this->description($this->summary);
	}

	$this->copyright('unknown');
	$this->release(1);
	$this->distribution("Slackware/tarball");
	$this->group("unknown");
	$this->origformat('tgz');
	$this->changelogtext('');
	$this->binary_info($this->runpipe(0, "ls -l '$file'"));

	# Now figure out the conffiles. Assume anything in etc/ is a
	# conffile.
	my @conffiles;
	open (FILELIST,"tar vtf $file | grep etc/ |") ||
		die "getting filelist: $!";
	while (<FILELIST>) {
		# Make sure it's a normal file. This is looking at the
		# permissions, and making sure the first character is '-'.
		# Ie: -rw-r--r--
		if (m:^-:) {
			# Strip it down to the filename.
			m/^(.*) (.*)$/;
			push @conffiles, "/$2";
		}
	}
	$this->conffiles(\@conffiles);

	# Now get the whole filelist. We have to add leading /'s to the
	# filenames. We have to ignore all files under /install/
	my @filelist;
	open (FILELIST, "tar tf $file |") ||
		die "getting filelist: $!";
	while (<FILELIST>) {
		chomp;
		unless (m:^install/:) {
			push @filelist, "/$_";
		}
	}
	$this->filelist(\@filelist);

	# Now get the scripts.
	foreach my $script (keys %{scripttrans()}) {
		$this->$script(scalar $this->runpipe(1, "tar Oxf '$file' install/${scripttrans()}{$script} 2>/dev/null"));
	}

	return 1;
}

=item unpack

Unpack tgz.

=cut

sub unpack {
	my $this=shift;
	$this->SUPER::unpack(@_);
	my $file=abs_path($this->filename);

	$this->do("cd ".$this->unpacked_tree."; tar xpf $file")
		or die "Unpacking of '$file' failed: $!";
	# Delete the install directory that has slackware info in it.
	$this->do("cd ".$this->unpacked_tree."; rm -rf ./install");

	return 1;
}

sub arch {
    my $self = shift; 
    # $self is the Alien::Package::Tgz object instance.

    # Call the imported 'arch' function from Alien::Package::Rpm.
    # Pass $self as the first argument, so the Rpm.pm 'arch' function
    # (which is written as a method) receives it as its own $this/$self.
    # Pass any other arguments received by Tgz::arch using @_.
    return Alien::Package::Rpm::arch($self, @_);
}

# Helper function for _format_slack_desc
sub _format_slack_desc_section {
    my ($pkgname, $text_content, $num_target_lines, $max_total_line_length) = @_;

    my $line_prefix_with_space = "$pkgname: ";
    my $line_prefix_no_space = "$pkgname:";
    # Max length for the actual content, after the prefix
    my $max_content_len = $max_total_line_length - length($line_prefix_with_space);
    # Ensure max_content_len is somewhat reasonable if pkgname is very long
    $max_content_len = 10 if $max_content_len < 10;

    my @formatted_lines;
    $text_content = "" if !defined $text_content; # Ensure defined

    my @segments = split /\n/, $text_content;
    # If text_content was empty, split results in one empty segment.
    # If text_content ended with \n, split might produce an extra empty segment.
    # We want to preserve intentional paragraph breaks (empty segments from \n\n).
    
    # Special case: if text_content is completely empty, segments will be [""]
    # and num_target_lines is 1, it should produce one "$pkgname:" line.
    # If text_content is non-empty but results in no words (e.g. "  \n  "),
    # it should also be handled gracefully.

    SEGMENT: foreach my $segment (@segments) {
        last SEGMENT if scalar(@formatted_lines) >= $num_target_lines;

        # Trim whitespace from segment. If it becomes empty, it's a paragraph break.
        $segment =~ s/^\s+|\s+$//g;

        if ($segment eq "") {
            push @formatted_lines, $line_prefix_no_space;
            next SEGMENT;
        }

        my @words = split /\s+/, $segment;
        next SEGMENT if !@words; # Should not happen if segment was non-empty after trim

        my $current_line_buffer = ""; # Holds content part of the line

        WORD: foreach my $word (@words) {
            if (scalar(@formatted_lines) >= $num_target_lines && $current_line_buffer eq "") {
                 # Already filled target lines and current buffer for this segment is empty
                last SEGMENT;
            }
            # Check if a single word itself is too long
            if (length($word) > $max_content_len) {
                # If buffer has content, push it first
                if ($current_line_buffer ne "") {
                    last SEGMENT if scalar(@formatted_lines) >= $num_target_lines;
                    push @formatted_lines, $line_prefix_with_space . $current_line_buffer;
                    $current_line_buffer = "";
                }
                # Push the long word, truncated, on its own line
                last SEGMENT if scalar(@formatted_lines) >= $num_target_lines;
                push @formatted_lines, $line_prefix_with_space . substr($word, 0, $max_content_len);
                # The rest of the word is lost, as per typical shell script behavior (often implicit)
                # Or, decide if $word should become the remainder: $word = substr($word, $max_content_len); and re-evaluate
                # For now, simply truncating and moving to next word in input.
                # Given the spec, it's more about fitting, so a very long word will just fill one line.
                next WORD; # Move to next word, current long word handled.
            }

            if ($current_line_buffer eq "") {
                $current_line_buffer = $word;
            } else {
                my $potential_line = $current_line_buffer . " " . $word;
                if (length($potential_line) <= $max_content_len) {
                    $current_line_buffer = $potential_line;
                } else {
                    last SEGMENT if scalar(@formatted_lines) >= $num_target_lines;
                    push @formatted_lines, $line_prefix_with_space . $current_line_buffer;
                    $current_line_buffer = $word;
                }
            }
        }# end WORD loop
        
        # Push any remaining content in buffer for the current segment
        if ($current_line_buffer ne "") {
            last SEGMENT if scalar(@formatted_lines) >= $num_target_lines;
            push @formatted_lines, $line_prefix_with_space . $current_line_buffer;
        }

    } # end SEGMENT loop

    # Pad with "$pkgname:" or truncate to meet exactly $num_target_lines
    while (scalar(@formatted_lines) < $num_target_lines) {
        push @formatted_lines, $line_prefix_no_space;
    }
    if (scalar(@formatted_lines) > $num_target_lines) {
        @formatted_lines = @formatted_lines[0 .. $num_target_lines - 1];
    }

    return @formatted_lines;
}

sub _format_slack_desc {
	my $this = shift;

	my $pkgname = $this->name() || "unknown"; # Should usually be defined
	my $summary = $this->summary();
	my $description = $this->description();
	my $homepage_url = ""; # Fixed as per requirement

	# Ensure summary is a single, trimmed line
	$summary = "" if !defined $summary;
	$summary =~ s/\n.*//s;    # Keep only the first line
	$summary =~ s/^\s+|\s+$//g; # Trim whitespace
	$summary = "No summary" if $summary eq "";


	$description = "" if !defined $description;
    # Newlines in description are paragraph separators, handled by _format_slack_desc_section

	my $screen_width = 72 + length($pkgname);

	my $ruler_header = "# HOW TO EDIT THIS FILE:\n# The \"handy ruler\" below makes it easier to edit a package description.\n# Line up the first '|' above the ':' following the base package name, and\n# the '|' on the right side marks the last column you can put a character in.\n# You must make exactly 11 lines for the formatting to be correct.  It's also\n# customary to leave one space after the ':' except on otherwise blank lines.\n\n";
	
	my $ruler_gap = ' ' x length($pkgname);
	my $ruler_base = $ruler_gap . "|-----handy-ruler--";
	# Screen width is total, ruler includes the final '|', so -1 from screen_width for filling
	my $ruler_fill_count = $screen_width - 1 - length($ruler_base);
	$ruler_fill_count = 0 if $ruler_fill_count < 0; # Ensure not negative
	my $ruler_line = $ruler_base . ('-' x $ruler_fill_count) . '|';

	my $complete_ruler_block = $ruler_header . $ruler_line . "\n";

	# Section 1: Summary (1 line)
	# The format "$pkgname ($summary)" is part of the text_content for this section
	my $summary_content_for_section = "$pkgname ($summary)";
	my @summary_section = _format_slack_desc_section($pkgname, $summary_content_for_section, 1, $screen_width);

	# Section 2: Empty line (1 line)
	# This is effectively an empty paragraph
	my @empty_section = _format_slack_desc_section($pkgname, "", 1, $screen_width);
    # Ensure it's just "$pkgname:" as per spec for empty lines
    $empty_section[0] = "$pkgname:" if @empty_section;


	# Section 3: Description (8 lines)
	my @description_section = _format_slack_desc_section($pkgname, $description, 8, $screen_width);

	# Section 4: Homepage (1 line)
	my @homepage_section = _format_slack_desc_section($pkgname, $homepage_url, 1, $screen_width);
    # Ensure it's just "$pkgname:" if homepage_url is empty
    if ($homepage_url eq "" && @homepage_section) {
        $homepage_section[0] = "$pkgname:";
    }


	my $all_content_lines = join("\n", @summary_section, @empty_section, @description_section, @homepage_section);
	
	return $complete_ruler_block . $all_content_lines . "\n";
}

=item prep

Adds a populated install directory to the build tree.

=cut

sub prep {
	my $this=shift;
	my $dir=$this->unpacked_tree || die "The package must be unpacked first!";
	my $install_dir = $dir."/install";
	my $install_made=0;

	# Check if install directory already exists (e.g. from unpacking)
	if (-d $install_dir) {
	    $install_made = 1;
	}

	# Generate and write slack-desc if description is meaningful
	my $description = $this->description();
	my $summary = $this->summary();
	if (defined $description && $description =~ /\S/ && $description ne "Converted tgz package" && $description ne $summary) {
		my $slack_desc_content = $this->_format_slack_desc();
		if ($slack_desc_content && $slack_desc_content =~ /\S/) {
			if (!$install_made) {
				mkdir($install_dir, 0755) 
					|| die "unable to mkdir $install_dir: $!";
				$install_made=1;
			}
			my $slack_desc_path = $install_dir."/slack-desc";
			open (SLACKDESC, ">$slack_desc_path") || die "Unable to open $slack_desc_path for writing: $!";
			print SLACKDESC $slack_desc_content;
			close SLACKDESC;
			chmod(0644, $slack_desc_path) || $this->warn("Could not chmod $slack_desc_path: $!");
		}
	}

	if ($this->usescripts) {
		foreach my $script (keys %{scripttrans()}) {
			my $data=$this->$script();
			my $out=$install_dir."/".${scripttrans()}{$script};
			next if ! defined $data || $data =~ m/^\s*$/;
			if (!$install_made) {
				mkdir($install_dir, 0755) 
					|| die "unable to mkdir $install_dir: $!";
				$install_made=1;
			}
			open (OUT, ">$out") || die "$out: $!";
			print OUT $data;
			close OUT;
			$this->do("chmod", 755, $out);
		}
	}
}

=item build

Build a tgz.

=cut

sub build {
	my $this=shift;
	my $arch = $this->arch();
	my $tgz=$this->name."-".$this->version."-".$arch."-1_alien.tgz";
	if (-x "/sbin/makepkg") {
		my $v=$Alien::Package::verbose;
		$Alien::Package::verbose=2;
		$this->do("cd ".$this->unpacked_tree."; makepkg -l y -c n ../$tgz .")
			or die "Unable to make pkg";
		$Alien::Package::verbose=$v;
	}
	else {
		die "Sorry, I cannot generate the .tgz file because /sbin/makepkg is not present.\n"
	}
	return $tgz;
}

=back

=head1 AUTHOR

Joey Hess <joey@kitenet.net>

=cut

1
