// Text checks on what the speech model returns (repeat loops, dropped lines). Run with `make test`.
import Foundation

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print((ok ? "  ok   " : "  FAIL ") + what)
    if !ok { failures += 1 }
}

print("Repeat loops")
check(TranscriptCleanup.collapsingRepeats("Nahini, chhah mein kya hai? 30 6. 30 6. 30 6. 30 6. 30 6. 30 6.") == "Nahini, chhah mein kya hai? 30 6.", "\"30 6.\" loop cut back to once")
check(TranscriptCleanup.collapsingRepeats("kitni baar 59 59 49 49 49 49 49 49 49 49 chhah to") == "kitni baar 59 59 49 chhah to", "\"49 49 49…\" cut back, the real \"59 59\" kept")
check(TranscriptCleanup.collapsingRepeats("haan haan, no no no, theek hai") == "haan haan, no no no, theek hai", "normal 2–3 repeats left alone")
check(TranscriptCleanup.collapsingRepeats("Aaj mujhe Olly ke saath template discuss karna hai.") == "Aaj mujhe Olly ke saath template discuss karna hai.", "normal sentence unchanged")
check(TranscriptCleanup.collapsingRepeats("") == "", "empty text")

print("Dropped lines")
check(TranscriptCleanup.isKnownHallucination("nan"), "\"nan\" dropped")
check(TranscriptCleanup.isKnownHallucination(" Nan. "), "\" Nan. \" dropped")
check(!TranscriptCleanup.isKnownHallucination("nanu ka ghar"), "\"nanu ka ghar\" kept")
let names = ["Olly", "Parul", "Vipul", "Alana", "MCP", "GitHub"]
check(TranscriptCleanup.isOnlyVocabulary("Olly, Parul, Vipul.", names), "a line that is just the names list is dropped")
check(!TranscriptCleanup.isOnlyVocabulary("Parul ka message aaya hai", names), "a real line with a name is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Olly!", names), "someone calling just \"Olly!\" is kept")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
