// Text checks on what the speech model returns (repeat loops, dropped lines, call echo). Run with `make test`.
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
check(TranscriptCleanup.isKnownHallucination("........................"), "a line of dots dropped")
check(!TranscriptCleanup.isKnownHallucination("nanu ka ghar"), "\"nanu ka ghar\" kept")
let names = ["Olly", "Parul", "Vipul", "Alana", "MCP", "GitHub"]
check(TranscriptCleanup.isOnlyVocabulary("Olly, Parul, Vipul.", names), "a line that is just the names list is dropped")
check(!TranscriptCleanup.isOnlyVocabulary("Parul ka message aaya hai", names), "a real line with a name is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Olly!", names), "someone calling just \"Olly!\" is kept")

print("Call echo (the mic hearing the other side through the speakers)")
let theirs = ["I can deploy this today after I check the screenshots."]
check(EchoFilter.removingEcho(from: "I can deploy this today after I check the screen shots.", heard: theirs) == nil,
      "a garbled copy of their words is dropped")
check(EchoFilter.removingEcho(from: "I can deploy this today after I check the screen shots. Perfect, please do that.", heard: theirs)
      == "Perfect, please do that.", "my reply after the echo is kept")
check(EchoFilter.removingEcho(from: "Theek hai, Parul ko bhi bata dena. Haan kal tak ho jaega main bata dunga.",
                              heard: ["Haan, kal tak ho jaega, main bata dunga."]) == "Theek hai, Parul ko bhi bata dena.",
      "Hinglish: my sentence before the echo is kept")
let question = "So what is the plan for the release on Friday?"
check(EchoFilter.removingEcho(from: question, heard: ["So I have been working on the tracker and it is almost done."]) == question,
      "my own sentence sharing common words with theirs is kept")
check(EchoFilter.removingEcho(from: "Ok.", heard: ["Is that fine with you?"]) == "Ok.", "a short reply of mine is kept")
check(EchoFilter.removingEcho(from: "Ok.", heard: ["Ok, thank you."]) == nil, "a short echo of theirs is dropped")
check(EchoFilter.removingEcho(from: "That's all from my side.Thanks everyone.", heard: ["That's all from my side."]) == "Thanks everyone.",
      "sentences glued without a space are split")
check(EchoFilter.removingEcho(from: question, heard: []) == question, "nothing heard from the call, nothing removed")
let once = EchoFilter.removingEcho(from: "Ok, over to you. I can deploy this today after I check the screen shots.", heard: theirs)
check(once == "Ok, over to you." && EchoFilter.removingEcho(from: once ?? "", heard: theirs) == once, "running it twice changes nothing more")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
