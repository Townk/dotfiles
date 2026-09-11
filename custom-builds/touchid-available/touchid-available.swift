// touchid-available — exit 0 when a biometric sensor can authenticate RIGHT NOW.
//
// presence decided its `touchid` lane by enumerating devices (`hidutil list`,
// `ioreg -rc AppleBiometricSensor`). That answers "is a sensor attached", which
// is not the same question: a wedged external Touch ID button still enumerates,
// and on a laptop the built-in sensor stays in the IO registry with the lid
// shut. Both cases routed password requests down a lane that could not deliver,
// and pinentry-touchid then fell back to pinentry-mac on its own — a GUI box
// where a fingerprint was promised, which reads as a bug rather than a
// degradation (measured 2026-09-11: an unplug/replug of the button was the
// whole difference, with `bioutil -r` reporting enrolled throughout).
//
// canEvaluatePolicy is the sensor subsystem's own answer to the question that
// matters, and it tracked that outage exactly: false while the button was
// wedged, true once it came back. It needs no entitlement and no real code
// signature — an ad-hoc binary gets a truthful answer — and it never prompts,
// so it is safe on the password path presence sits on.
//
// Exit status only, no output: presence needs a branch, not a message.
import LocalAuthentication

exit(LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) ? 0 : 1)
