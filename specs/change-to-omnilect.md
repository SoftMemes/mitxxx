# Change to Omnilect Specification

> **Version**: 1.0 (April 2026)
> **Status**: Draft
> **Last Updated**: 2026-04-15

## Description

Change all package identifiers and any namespaces to reference `app.omnilect` as the package — I now have the domain `omnilect.app`. Do not change the user-facing copy, only the identifiers.

This also needs to update or create new apps in Firestore and register apps in Play Store / Apple Developer — automate this as much as is possible to do with command line tools and tell me what actions I need to take. Consider Fastlane — interview me about options here.

I want to ultimately be able to create both internal releases via Firebase App Distribution and public ones for the App Store.

Make it so that these use separate package identifiers and builds so that I can have both versions installed on my phone — the developer version and the stable one. Use `app.omnilect.dev` as the package for the dev version (tied to Firebase App Distribution).

---

*This is a draft specification. Use `/refine-spec change-to-omnilect` to develop it further with structured questioning and technical details.*
