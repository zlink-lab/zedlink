#!/usr/bin/env python3
"""
Checks the App Store profile against the certificate and the app, then writes the export options.

    python3 ios/ci/ios-ci-signing.py <profile.plist> <identity SHA-1> <identity name> [<share profile.plist>]

Taken from the TestFlight lane of Touch VN and RestoApp touch (the same team, the same certificate).
ios-testflight.yml runs it after `security cms -D` has decoded IOS_PROFILE_BASE64 and the .p12 has
gone into the keychain. Every mismatch it looks for is one xcodebuild would also find, twenty
minutes later and in words that do not say which secret is wrong: a profile for another app, a
development or ad-hoc profile, a profile made for another certificate, a profile without Push
(the app's entitlements ask for aps-environment).

The bundle id and the team come from IOS_BUNDLE_ID and IOS_TEAM_ID, the values the archive step
passes to xcodebuild. project.yml keeps dev.zedlink.app for the simulator builds.

With a fourth argument (IOS_SHARE_PROFILE_BASE64 decoded) the build embeds the ZLinkShare
extension: the share profile is checked against <bundle>.share, both profiles must carry the App
Group group.cx.m42.zlink, and the script prints both UUIDs ("<app> <share>").

Writes build/ExportOptions.plist (for this run only, never committed) and prints the profile's
UUID, the name the runner files it under and the archive step signs with.
"""
import hashlib
import os
import plistlib
import sys


APP_GROUP = "group.cx.m42.zlink"


def check(profile_path, secret, team, bundle, identity_sha1, identity_name, push, app_group):
    with open(profile_path, "rb") as f:
        profile = plistlib.load(f)
    entitlements = profile.get("Entitlements", {})

    problems = []
    app_id = entitlements.get("application-identifier", "")
    if app_id != f"{team}.{bundle}":
        problems.append(f"it is for {app_id or 'no App ID'}, not {team}.{bundle}")
    if "ProvisionedDevices" in profile or entitlements.get("get-task-allow"):
        problems.append("it is a development or ad-hoc profile; TestFlight takes an App Store one")
    certificates = {hashlib.sha1(c).hexdigest().upper() for c in profile.get("DeveloperCertificates", [])}
    if identity_sha1.upper() not in certificates:
        problems.append(f"it was made for another certificate than the one in the .p12 ({identity_name})")
    if push and entitlements.get("aps-environment") != "production":
        problems.append("it has no Push (aps-environment production); run `asc setup --push` and "
                        "update the secret")
    if app_group and APP_GROUP not in entitlements.get("com.apple.security.application-groups", []):
        problems.append(f"it has no App Group {APP_GROUP}; enable App Groups for {bundle}, add the group, "
                        "regenerate the profile and update the secret (see ios/README-share-extension.md)")
    if problems:
        for problem in problems:
            print(f"::error::{secret} «{profile.get('Name', '?')}»: {problem}", file=sys.stderr)
        sys.exit(1)
    return profile["UUID"]


def main(profile_path, identity_sha1, identity_name, share_profile_path=None):
    team, bundle = os.environ["IOS_TEAM_ID"], os.environ["IOS_BUNDLE_ID"]
    share_bundle = os.environ.get("IOS_SHARE_BUNDLE_ID") or f"{bundle}.share"
    with_share = share_profile_path is not None
    uuid = check(profile_path, "IOS_PROFILE_BASE64", team, bundle, identity_sha1, identity_name,
                 push=True, app_group=with_share)
    profiles = {bundle: uuid}
    share_uuid = None
    if with_share:
        share_uuid = check(share_profile_path, "IOS_SHARE_PROFILE_BASE64", team, share_bundle,
                           identity_sha1, identity_name, push=False, app_group=True)
        profiles[share_bundle] = share_uuid

    options = {
        "method": "app-store-connect",
        "destination": "upload",           # straight to App Store Connect, with the API key
        "teamID": team,
        "signingStyle": "manual",
        "signingCertificate": identity_name,
        "provisioningProfiles": profiles,
        "uploadSymbols": True,
        "manageAppVersionAndBuildNumber": False,  # the build number is the run number
    }
    os.makedirs("build", exist_ok=True)
    with open("build/ExportOptions.plist", "wb") as f:
        plistlib.dump(options, f)

    print(f"{uuid} {share_uuid}" if share_uuid else uuid)


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    main(*sys.argv[1:])
