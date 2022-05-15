#!/usr/bin/env python3

import os
import sys
import shutil
import argparse

tools = [ "opm", "podman"]

parser = argparse.ArgumentParser(
    description='Build and push Tackle index images for a new release',
    epilog='This script is used to assemble and push new index images for a new Tackle release/version. Please ensure you are properly logged in to quay and have enough permissions in target repos prior executing.')

parser.add_argument('--old-version', dest='old_version', required=True, type=str, help='Old index image version tag, version must follow semver format (i.e 2.0.0)')
parser.add_argument('--new-version', dest='new_version', required=True, type=str, help='New index image version tag, version must follow semver format (i.e 2.0.0)')
parser.add_argument('--release-prefix', dest='release_prefix', default='v', type=str, help='release_prefix is the scheme used for branching project (i.e release-v), default is v')
parser.add_argument('--quay-org', dest='quay_org', default='quay.io/konveyor', type=str, help='Quay organization for this project, default is quay.io/konveyor')
parser.add_argument('--quay-bundle-repo', dest='quay_bundle_repo', default='tackle2-operator-bundle', type=str, help='Quay repo which holds bundleimages for this project, default is tackle2-operator-bundle')
parser.add_argument('--quay-index-repo', dest='quay_index_repo', default='tackle2-operator-index', type=str, help='Quay repo which holds index images for this project, default is tackle2-operator-index')

args = parser.parse_args()

def run(cmdline):
    r = os.system(cmdline)
    if r >0:
        print("Program exited abnormally with return code %d" % r)
        sys.exit(1)
    return

# Sanity check

for cmd in tools:
    f_check = shutil.which(cmd) is not None
    if not f_check:
        print(cmd,"is required and could not be found in PATH, exiting..")
        sys.exit(1)

# Assemble pullspecs

old_index_pullspec = "%s/%s:%s%s" % (args.quay_org, args.quay_index_repo, args.release_prefix, args.old_version)
new_index_pullspec = "%s/%s:%s%s" % (args.quay_org, args.quay_index_repo, args.release_prefix, args.new_version)
latest_index_pullspec = "%s/%s:latest" % (args.quay_org, args.quay_index_repo)
new_bundle_pullspec = "%s/%s:%s%s" % (args.quay_org, args.quay_bundle_repo, args.release_prefix, args.new_version)
latest_bundle_pullspec = "%s/%s:latest" % (args.quay_org, args.quay_bundle_repo)

# Build and push index images

print("\n######## Add new bundle %s to old index image %s ########\n" % (args.new_version, args.old_version))
cmd = "opm index add -c podman -f %s --bundles %s --tag %s" % (old_index_pullspec, new_bundle_pullspec, new_index_pullspec)
run(cmd)

print("\n######## Push updated index %s as a new image ########\n" % args.new_version)
cmd = "podman push %s" % new_index_pullspec
run(cmd)

print("\n######## Add latest bundle to the new index %s ########\n" % args.new_version)
cmd = "opm index add -c podman -f %s --bundles %s --tag %s" %(new_index_pullspec, latest_bundle_pullspec, latest_index_pullspec)
run(cmd)

print("\n######## Push complete index as latest ########\n")
cmd = "podman push %s" % latest_index_pullspec
run(cmd)
