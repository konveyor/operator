#!/usr/bin/env python3
#
# This is a Konveyor 0.2->0.3 upgrade Assessments migration script (migrates legacy Pathfinder data).
# 
# Based on Konveyor CLI tool https://github.com/konveyor/tackle2-hub/tree/main/hack/tool
#
# Usage:
# $ ./migrate-pathfinder-assessments --pathfinder-url http://pathfinder.svc --hub-base-url http://hub.svc:8080 --token ""
#

import argparse
import json
import requests

###############################################################################

parser = argparse.ArgumentParser(description='Konveyor Pathfinder Assessments migration script.')
parser.add_argument('-v','--verbose', dest='verbose', action='store_const', const=True, default=False,
                    help='Print verbose output (including all API requests).')
parser.add_argument('-p','--pathfinder-url', type=str, help='In-cluster Pathfinder endpoint URL.',
                    nargs='?', default='', required=True)
parser.add_argument('-b','--hub-base-url', type=str, help='In-cluster Hub API endpoint URL.',
                    nargs='?', default='', required=True)
parser.add_argument('-t','--token', type=str, help='Bearer authorization token.',
                    nargs='?', default='')
args = parser.parse_args()

###############################################################################

def debugPrint(str):
    if args.verbose:
        print(str)

def apiJSON(url, token, data=None, method='GET', ignoreErrors=False):
    debugPrint("Querying: %s" % url)
    if method == 'DELETE':
        r = requests.delete(url, headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}, verify=False)
    elif method == 'POST':
        debugPrint("POST data: %s" % json.dumps(data))
        r = requests.post(url, data=json.dumps(data), headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}, verify=False)
    elif method == 'PATCH':
        debugPrint("PATCH data: %s" % json.dumps(data))
        r = requests.patch(url, data=json.dumps(data), headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}, verify=False)
    elif method == 'PUT':
        debugPrint("PUT data: %s" % json.dumps(data))
        r = requests.put(url, data=json.dumps(data), headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}, verify=False)
    else: # GET
        r = requests.get(url, headers={"Authorization": "Bearer %s" % token, "Content-Type": "application/json"}, verify=False)

    if not r.ok:
        if ignoreErrors:
            debugPrint("Got status %d for %s, ignoring" % (r.status_code, url))
        else:
            print("ERROR: API request failed with status %d for %s" % (r.status_code, url))
            exit(1)

    if r.text is None or r.text ==  '':
        return

    debugPrint("Response: %s" % r.text)

    respData = json.loads(r.text)
    if '_embedded' in respData:
        debugPrint("Unwrapping Tackle1 JSON")
        return respData['_embedded'][url.rsplit('/')[-1].rsplit('?')[0]] # unwrap JSON response (e.g. _embedded -> application -> [{...}])
    else:
        return respData # raw return JSON (Tackle2, Pathfinder)
###############################################################################

def migrateAssessments(pathfinder_url, hub_base_url, token):
    cnt = 0
    apps = apiJSON(hub_base_url + "/applications", token)
    print("There are %d Applications, looking for their Assessments.." % len(apps))
    for app in apps:
        # If there would be more assessments, only first one is migrated.
        for passmnt in apiJSON(pathfinder_url + "/assessments?applicationId=%d" % app['id'], token):
            print("# Assessment for Application %s" % passmnt["applicationId"])
            appAssessmentsPath = "/applications/%d/assessments" % passmnt["applicationId"]
            # Skip if Assessment for given Application already exists
            if len(apiJSON(hub_base_url + appAssessmentsPath, token)) > 0:
                print("  Assessment already exists, skipping.")
                continue
            
            # Prepare new Assessment
            passmnt = apiJSON(pathfinder_url + "/assessments/%d" % passmnt['id'], token)
            assmnt = dict()
            assmnt['questionnaire'] = {"id": 1} # Default new Questionnaire "Pathfinder Legacy"
            assmnt['application'] = {"id": passmnt["applicationId"]}
            assmnt['stakeholders'] = []
            for sh in passmnt['stakeholders']:
                assmnt['stakeholders'].append({"id": sh})
            assmnt['stakeholderGroups'] = []
            for shg in passmnt['stakeholderGroups']:
                assmnt['stakeholderGroups'].append({"id": shg})

            # Transformate Questions, Answers and related structures
            for category in passmnt['questionnaire']['categories']:
                del category['id']
                category['name'] = category.pop('title')
                for question in category["questions"]:
                    del question['id']
                    question["text"] = question.pop('question')
                    question["explanation"] = question.pop('description')
                    question["answers"] = question.pop('options')
                    for answer in question['answers']:
                        del answer['id']
                        answer['text'] = answer.pop('option')
                        answer['selected'] = answer.pop('checked')
                        answer['risk'] = answer['risk'].lower()
                        if answer['risk'] == "amber":
                            answer['risk'] = "yellow"
            assmnt['sections'] = passmnt['questionnaire']['categories']

            # Post the Assessment
            apiJSON(hub_base_url + appAssessmentsPath, token, data=assmnt, method='POST')
            cnt += 1
            print("Assessment submitted.")
    return cnt


###############################################################################

print("Starting Pathfinder Assessments to Konveyor Assessment migration.")

appCnt = migrateAssessments(args.pathfinder_url, args.hub_base_url, args.token)

print("Done. %d new Assessment(s) for Application(s) were migrated!" % appCnt)

###############################################################################
