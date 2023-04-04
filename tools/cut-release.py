#!/usr/bin/env python3

import os
import argparse
import jinja2
import datetime

# Files to template, the template name to be used and target file path relative to --project-path
files = { 1: {'template': 'clusterserviceversion.yaml.j2', 'path': 'bundle/manifests/konveyor-operator.clusterserviceversion.yaml'},
          2: {'template': 'annotations.yaml.j2', 'path': 'bundle/metadata/annotations.yaml'},
          3: {'template': 'bundle.Dockerfile.j2', 'path': 'bundle.Dockerfile'},
          4: {'template': 'tackle-k8s.yaml.j2', 'path': 'tackle-k8s.yaml'}}

parser = argparse.ArgumentParser(
    description='Prepare a new Tackle project release',
    epilog='This script is used to prepare a new release branch for Tackle, please review changes before submitting PR.')

parser.add_argument('--version', dest='version', required=True, type=str, help='version must follow semver format (i.e 2.0.0) unless latest')
parser.add_argument('--release_prefix', dest='release_prefix', default='v', type=str, help='release_prefix is the scheme used for branching project (i.e release-v), default is v')
parser.add_argument('--channel', dest='channel', type=str, help='OLM channel must follow semver format (i.e release-v2.0), if not supplied will be derived to X.Y from version')
parser.add_argument('--templates-path', dest='templates_path', type=str, help='Absolute path to directory containing jinja2 templates, default is templates')
parser.add_argument('--project-path', dest='project_path', type=str, help='Absolute path to directory containing project root, where rendered templates will output, default is CWD')

args = parser.parse_args()

# Define templating func
def template(rendered_file_name, template_file_name):

    print ("Rendering %s" % rendered_file_name)
    rendered_file_path = os.path.join(args.project_path, rendered_file_name)

    environment = jinja2.Environment(loader=jinja2.FileSystemLoader(args.templates_path),
                                     keep_trailing_newline=True)
    output_text = environment.get_template(template_file_name).render(render_vars)

    with open(rendered_file_path, "w") as output_file:
        output_file.write(output_text)
    return

# Init script path
script_path = os.path.dirname(os.path.abspath(__file__))

# Set project_path defaults if not supplied
if not args.project_path:
    for f_id, f_info in files.items():
        f_dirname = os.path.dirname(f_info['path'])
        d = os.path.join(script_path, f_dirname)
        if not os.path.exists(d):
            os.makedirs(d)
    args.project_path = script_path

# Set templates defaults if not supplied
if not args.templates_path:
    args.templates_path = os.path.join(script_path, "templates")

# Set channel defaults if not supplied and special cases
if args.version == "latest":
    args.channel = "development"
if not args.channel:
   short_version = args.version.rsplit(".",1)[0]
   args.channel = args.release_prefix + short_version

# Handle tags and version special cases
if args.version == "latest":
    tag = "latest"
    args.version = "99.0.0"
else:
    tag = args.release_prefix + args.version

# Set creation time (utc iso formatted)
t = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).isoformat()
date = t[:-7] + 'Z'

# Init rendering vars
render_vars = {}

render_vars["version"] = args.version
render_vars["release_prefix"] = args.release_prefix
render_vars["tag"] = tag
render_vars["channel"] = args.channel
render_vars["date"] = date
render_vars["namespace"] = "konveyor-tackle"

# Walk all values and print before templating

#for key, value in render_vars.items():
#    print(key,":", value)

# Template

for f_id, f_info in files.items():
    template(f_info['path'],f_info['template'])
