// Text checks on what the speech model returns (loops, dropped lines, call echo). Run with `make test`.
// Every sentence and name here is made up.
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
check(TranscriptCleanup.collapsingRepeats("Aaj mujhe Asha ke saath template discuss karna hai.") == "Aaj mujhe Asha ke saath template discuss karna hai.", "normal sentence unchanged")
check(TranscriptCleanup.collapsingRepeats("") == "", "empty text")
check(TranscriptCleanup.collapsingRepeats("Sure sure sure sure. Yeah.") == "Sure. Yeah.", "the full stop after a cut loop is kept")
check(TranscriptCleanup.collapsingRepeats("Haan, theek, theekh, theek, theeke, theek, chalo") == "Haan, theek, chalo", "a word loop with small spelling changes is cut back")
check(TranscriptCleanup.collapsingRepeats("Pehle interior, exterior, exterior, exterior dikhao") == "Pehle interior, exterior, exterior, exterior dikhao", "different words that look alike are not a loop")
check(TranscriptCleanup.collapsingRepeats("Yes, yes, yes, yes. Then we go.") == "Yes. Then we go.", "a cut loop keeps the full stop that ended it")
check(TranscriptCleanup.collapsingRepeats("Sales were 2021, 2022, 2023, 2024 and then it dropped.") == "Sales were 2021, 2022, 2023, 2024 and then it dropped.", "a series of years is not a loop")
check(TranscriptCleanup.collapsingRepeats("Row 1001, row 1002, row 1003, row 1004 are broken.") == "Row 1001, row 1002, row 1003, row 1004 are broken.", "a series of numbers is not a loop")
check(TranscriptCleanup.collapsingRepeats("Idhar udhar idhar udhar dekh raha tha") == "Idhar udhar idhar udhar dekh raha tha", "rhyming pairs are not a loop")

print("Loops that change a little each time")
let seconds = 6.0
func cleaned(_ text: String, _ seconds: Double = seconds) -> String? { TranscriptCleanup.cleaned(text, seconds: seconds, vocabulary: names) }
let names = ["Asha", "Ravi", "Meera", "Kabir", "MCP", "GitHub"]
check(cleaned("Main kal aa raha hoon.Mein kal aa rahaa hoon.Main kal aa raha hun.Main kal aa raka hoon.Main kal aa raha hoon.") == "Main kal aa raha hoon.",
      "a sentence repeated with small changes, glued together, is cut to the first")
check(cleaned("Report bhej do. And the first. And the first. And the second. And the first. And the first.") == "Report bhej do. And the first.",
      "\"And the first. And the second…\" is cut to once, the real sentence before it kept")
check(cleaned("Haan ji. Haan ji. Kal milte hain.") == "Haan ji. Haan ji. Kal milte hain.", "saying something twice is left alone")
check(cleaned("Ok. Ok. Ok. Chalo.") == "Ok. Ok. Ok. Chalo.", "three short \"Ok.\" are left alone")
check(cleaned("Ok. Ok. Ok. Ok. Ok. Chalo.") == "Ok. Chalo.", "five are a loop")
let list = "Send it to the design team. Send it to the sales team. Send it to the support team."
check(cleaned(list) == list, "three parallel instructions are kept")
let questions = "What is the plan? What is the budget? What is the timeline?"
check(cleaned(questions) == questions, "three parallel questions are kept")
check(cleaned("Yeah sure we can discuss.Then how do we plan it?") == "Yeah sure we can discuss. Then how do we plan it?", "glued sentences get their space")
check(cleaned("The stay time is 1.5 seconds, version 2.0 is out.") == "The stay time is 1.5 seconds, version 2.0 is out.", "decimals are not split")

print("More words than fit in the time")
let loop = "Yeah it does, " + Array(repeating: "there is a thing, let me show you, I see, it does not even like that,", count: 6).joined(separator: " ")
let trimmed = cleaned(loop, 7) ?? ""
check(trimmed.hasPrefix("Yeah it does, there is a thing,") && trimmed.split(separator: " ").count <= 28,
      "a \(loop.split(separator: " ").count)-word loop from 7 s of audio is cut to what fits (\(trimmed.split(separator: " ").count) words)")
check(cleaned("Abhi tak kuchh bheja nahin hai usne mujhe.Abhe tak kuch bheja nahi hai usne mujhe bheja nahin tak mujhe usne.", 1.6) == "Abhi tak kuchh bheja nahin hai usne mujhe.",
      "23 words from 1.6 s of audio: the first sentence is kept whole")
let fast = "To yahi par to do baar aaega yahaan saat baar aaega na bas"
check(cleaned(fast, 2) == fast, "fast real speech (13 words in 2 s) is kept whole")
let long = Array(repeating: "Then we looked at the numbers for the quarter and decided to wait.", count: 1).joined() + " After that the team moved the launch to next month because the vendor was late with the parts."
check(cleaned(long, 12) == long, "a long normal line is kept whole")

print("Dropped lines")
check(TranscriptCleanup.isKnownHallucination("nan"), "\"nan\" dropped")
check(TranscriptCleanup.isKnownHallucination(" Nan. "), "\" Nan. \" dropped")
check(TranscriptCleanup.isKnownHallucination("........................"), "a line of dots dropped")
check(!TranscriptCleanup.isKnownHallucination("nanu ka ghar"), "\"nanu ka ghar\" kept")
check(cleaned("'s'sh" + String(repeating: "h", count: 180), 2) == nil, "\"'s'shhhhhhhh…\" dropped")
check(cleaned(String(repeating: "'", count: 60) + "OO" + String(repeating: "'", count: 60), 3) == nil, "apostrophes with a stray \"OO\" dropped")
check(TranscriptCleanup.isRunaway("la di la da la la di da la di la da la la di da"), "a few words going round are not speech")
check(!TranscriptCleanup.isRunaway("We will look at the numbers and then we will decide what we do."), "a normal sentence that reuses words is speech")
check(cleaned("Haaaaaan theek hai", 2) == "Han theek hai", "a drawn-out word is shortened, the line kept")
check(cleaned("Budget is 10000 rupees and 2000000 for the year.", 4) == "Budget is 10000 rupees and 2000000 for the year.", "numbers with repeated digits are kept")
check(cleaned("1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12.", 8) == "1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12.", "counting out loud is kept")

print("Names list")
check(TranscriptCleanup.isOnlyVocabulary("Asha, Ravi, Meera.", names), "a line that is just the names list is dropped")
check(TranscriptCleanup.isOnlyVocabulary("Aurs, MCP, MCB, MCP, MCP, MCS, MCP.", names), "the names list with near misses mixed in is dropped")
check(!TranscriptCleanup.isOnlyVocabulary("Meera ka message aaya hai", names), "a real line with a name is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Asha!", names), "someone calling just \"Asha!\" is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Asha and Ravi.", names), "\"Asha and Ravi.\" is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Asha, Ravi and Meera.", names), "\"Asha, Ravi and Meera.\" is kept")
check(!TranscriptCleanup.isOnlyVocabulary("Meera, Kabir, Asha aa gaye", names), "names in a sentence are kept")
check(!TranscriptCleanup.isOnlyVocabulary("Asha, Ravi, Meera and Kabir.", names), "four names joined by \"and\" are a real answer")

print("Call echo (the mic hearing the other side through the speakers)")
let theirs = ["I can deploy this today after I check the screenshots."]
check(EchoFilter.removingEcho(from: "I can deploy this today after I check the screen shots.", heard: theirs) == nil,
      "a garbled copy of their words is dropped")
check(EchoFilter.removingEcho(from: "I can deploy this today after I check the screen shots. Perfect, please do that.", heard: theirs)
      == "Perfect, please do that.", "my reply after the echo is kept")
check(EchoFilter.removingEcho(from: "Theek hai, Meera ko bhi bata dena. Haan kal tak ho jaega main bata dunga.",
                              heard: ["Haan, kal tak ho jaega, main bata dunga."]) == "Theek hai, Meera ko bhi bata dena.",
      "Hinglish: my sentence before the echo is kept")
let question = "So what is the plan for the release on Friday?"
check(EchoFilter.removingEcho(from: question, heard: ["So I have been working on the tracker and it is almost done."]) == question,
      "my own sentence sharing common words with theirs is kept")
check(EchoFilter.removingEcho(from: "Ok.", heard: ["Is that fine with you?"]) == "Ok.", "a short reply of mine is kept")
check(EchoFilter.removingEcho(from: "Ok.", heard: ["Ok, thank you."]) == nil, "a short echo of theirs is dropped")
check(EchoFilter.removingEcho(from: "That's all from my side.Thanks everyone.", heard: ["That's all from my side."]) == "Thanks everyone.",
      "sentences glued without a space are split")
check(EchoFilter.removingEcho(from: question, heard: [String]()) == question, "nothing heard from the call, nothing removed")
let once = EchoFilter.removingEcho(from: "Ok, over to you. I can deploy this today after I check the screen shots.", heard: theirs)
check(once == "Ok, over to you." && EchoFilter.removingEcho(from: once ?? "", heard: theirs) == once, "running it twice changes nothing more")

print("Call echo, by time")
let start = Date(timeIntervalSince1970: 1_000)
func line(_ text: String, _ source: TranscriptLine.Source, from: Double, to: Double) -> TranscriptLine {
    TranscriptLine(start: start.addingTimeInterval(from), end: start.addingTimeInterval(to), source: source, text: text, language: nil)
}
let monologue = line("Ok so first we update the tracker, then we check every screen one by one, then we write the notes for the team, and after all that we send the build to the client for review on Friday morning.", .others, from: 0, to: 20)
check(EchoFilter.removingEcho(from: line("Ok.", .me, from: 19.5, to: 20.2), heard: [monologue]) == "Ok.",
      "my \"Ok.\" at the end of their 20 s line is kept, though they said \"ok\" at its start")
check(EchoFilter.removingEcho(from: line("Ok so first we update the tracker.", .me, from: 0.2, to: 2.5), heard: [monologue]) == nil,
      "the same words at the same moment are echo")
check(EchoFilter.removingEcho(from: line("Then we write the notes for the team. Haan, main bhej dunga.", .me, from: 9, to: 14), heard: [monologue])
      == "Haan, main bhej dunga.", "echo in the middle of their line is found, my reply kept")
check(EchoFilter.removingEcho(from: line(question, .me, from: 30, to: 33), heard: [monologue]) == question, "a line said after theirs ended is untouched")

print(failures == 0 ? "\nall passed" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
