#!/bin/sh
cp debian/tests/data/* $AUTOPKGTEST_TMP
cd $AUTOPKGTEST_TMP

alien --to-rpm *
