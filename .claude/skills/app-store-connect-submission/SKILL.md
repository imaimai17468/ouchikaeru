---
name: app-store-connect-submission
description: Inspect, prepare, and operate App Store Connect submissions for Ouchikaeru, including review rejections, review notes, physical-device recordings, replies, resubmission, and final status verification. Use when handling App Review or release-submission work; do not use for ordinary Swift development alone.
---

# App Store Connect submission

Handle the submission as a staged external workflow. Inspect first, keep claims consistent with the shipped build and evidence, and verify every saved or submitted state by reading it back.

## Load the relevant context

- Read `AGENTS.md` before repository work.
- Read [references/project-facts.md](references/project-facts.md) before writing review information or describing the app.
- Read [references/review-response.md](references/review-response.md) when responding to a rejection or preparing App Review notes.
- Re-check the repository when a claim may have changed. The references are starting points, not substitutes for the current code or App Store Connect state.

## Access and tool choice

1. Prefer an authenticated browser automation tool that can inspect and interact with the user's existing App Store Connect session.
2. On macOS, a logged-in Chrome tab may be automated with AppleScript JavaScript execution when Chrome permits JavaScript from Apple Events.
3. If a visible Chrome window exists but AppleScript reports no windows, check for a separate automation Chrome process. Never terminate the user's normal browser. Ask before terminating an automation-only process.
4. Stop for login, password, passkey, CAPTCHA, or two-factor authentication and let the user complete it. Never request or expose session cookies.
5. Use current official Apple documentation for review rules, OS-release status, required metadata, entitlements, and submission behavior. Do not rely on remembered policy when it may have changed.

## Workflow

### 1. Inspect

- Read the current app version, build number, submission ID, item status, guideline, full Apple message, timestamps, and existing App Review notes.
- Keep contact details, device identifiers, coordinates, and credentials out of chat output, repository files, and logs.
- Distinguish an information request or metadata issue from a binary defect. Do not change code unless the evidence requires it and the user asks for the fix.

### 2. Establish app facts

- Verify purpose, audience, access steps, authentication, purchases, user-generated content, external services, regional behavior, and regulated-content status against the current repository.
- Never claim that a recording, attachment, test, account, authorization, or feature exists until it has been verified.
- If Swift must change, follow `AGENTS.md`, including formatting, checks, the required Xcode build, and explicit-path staging. Preserve unrelated changes.

### 3. Prepare review material

- Answer every numbered question from Apple in the same order.
- Put required information both in the App Review reply and in the version's App Review Notes when Apple requests both.
- Keep each field below its current App Store Connect limit; target at most 3,500 UTF-8 bytes when the displayed limit is 4,000 so last-minute corrections fit.
- Use English for an English review request unless the user asks otherwise. Keep UI labels in Japanese where they help the reviewer follow the app.
- Save drafts before final submission and reload the page to confirm the server retained them.

### 4. Validate evidence

- For a requested physical-device video, confirm it was captured on a supported physical device running the latest publicly released OS on the recording date.
- The recording must begin before the app is launched, show the icon being tapped, avoid minutes of debugger-induced blank UI, and demonstrate the typical flow Apple requested.
- Include account creation/login/deletion, moderation, and paid-content flows only when the app has them. Explicitly state when they do not apply.
- Inspect the media before upload. Run `scripts/inspect-review-recording.sh <video>` when `ffprobe` and `ffmpeg` are available, then view both generated contact sheets.
- Reject or request a new recording when it contradicts the response, omits a required flow, exposes sensitive information, starts after launch, or uses an outdated OS.
- Do not add recordings, extracted frames, device state, coordinates, or App Store API responses to the repository.

### 5. Apply and submit

- Updating fields, saving drafts, and attaching evidence are external writes. Do them only when the user's request authorizes preparation or correction.
- Immediately before sending the reply and again before resubmitting, require explicit authorization unless the user already explicitly asked for those exact actions in the current task.
- Verify the attachment filename is visible and upload processing has completed before sending the reply.
- After sending, read back the posted message. Then make the rejected version ready for review and resubmit only if all requested items are present.
- Never cancel a submission, delete a submitted item, change price or availability, release an approved version, or upload a new binary unless the user explicitly requested that action.

### 6. Verify and report

- Reload App Store Connect and report the resulting submission and item statuses, version/build, submission ID, and which artifacts were sent.
- Say clearly what remains pending. Do not equate a clicked button with a successful server-side transition.

## Stop conditions

Stop without sending or resubmitting when authentication is required, required evidence is missing or invalid, the page target is ambiguous, the live app differs from the prepared response, upload processing failed, or App Store Connect reports a validation error. Preserve a useful draft and tell the user the single next action needed.
