# Maintain local signing

- Run `bash scripts/setup-local-signing.sh` once per Mac.
- Keep the generated certificate and private key in the login Keychain. Reuse them for every build.
- Run `bash scripts/build-app.sh` to sign with `Clipboard Library Local Signing`.
- Set `CLIPBOARD_SIGNING_IDENTITY` to select another installed certificate by name.
- Grant Accessibility access again after switching from the previous ad-hoc signature.
- Compare `codesign -d -r- 'outputs/Clipboard Library.app'` across builds. Require the same bundle identifier and certificate fingerprint.
- Verify permission retention after approving the new identity and rebuilding changed code.
- Keep the app at the same path. Avoid alternating between copies.
- Use an Apple-issued certificate for distribution. Treat this self-signed certificate as local development signing only.
- Keep clipboard encryption separate from signing. Store clipboard encryption keys in the local application-support file; use Keychain only for the build signing identity.
