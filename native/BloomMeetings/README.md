# Bloom Meetings

A separate, local-only application target in Bloom's Muesli fork. This target does not link Muesli's app shell, TelemetryDeck, Sparkle, CloudKit, provider integrations, dictation, screen history, or computer-use features.

The signed app sandbox has **no network client or server entitlement**. Models are included at packaging time. There is no account or background upload. Export is a user-selected local Markdown file. Do not add networking to this target without a deliberate review of the data boundary.

Status: implementation in progress; not a replacement release yet. The upstream Muesli application is not this build.

The initial acceptance checks are local file transcription, microphone and system-audio capture, a visible recording indicator, durable local recordings on transcription failure, and a denied network probe in the packaged application. Meeting detection and Bloom export must not be represented as complete before their end-to-end checks pass.
