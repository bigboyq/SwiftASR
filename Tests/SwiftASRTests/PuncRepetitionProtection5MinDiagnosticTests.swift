import Foundation
import Testing
@testable import SwiftASR

/// Diagnostic test: simulate the 5min 精修 token stream through the production
/// shape (ASR emits no punctuation, but we re-attach the 精修 punctuation as
/// the hypothetical Punc model output) and verify `protectRepetition` only
/// fires on the 2 real 吞字 cases (L20 / L51), not on any other terminal
/// punctuation position in the 5min slice.
///
/// This is a regression guard against over-recall: the post-pass must not
/// silently clear punctuation in places that are not actual repetitions.
@Test func adhd2_5min_protectRepetition_firesOnlyOnL20AndL51() throws {
    let adhd2Fixture = """
    就是那种你活不，我在乎你别搞我就行啊，。就。你饶了我吧，不要扎，。就别扎。对你别扎我手里，我真是害怕了，而且我是那种风险型人格，我真是怕这么事儿，
    我也不喜欢，
    太吓人了。可是这话就是说这话说难听，但不好知道该怎么弄。你。哎，好饿。快呀，我要吃菌子，。
    你不要这么着急的，见小人，。
    哎，小人已经见够多了，活着太满了。啊，走。手是在这儿吗？不哦，好的，。
    好多我们内存的二楼。
    对什么？他来帮我叫什么？
    我是老婆，
    叫什么玩意儿？hbm。
    掏定律啊，这还挺好玩儿。
    你看有一个直梯。
    哦，几楼啊，六楼的那座直梯啊，哎对，。哎呀，别穿了。得回杭啊，首席不管怎么样，还是要见一下的。哎，。虽然我觉得见了也没有什么意义，也不会。有什么意义，。
    有有有，见了就是意义
    哦，这个。
    你主动约了手席，还见到他了，还给他送了奶茶
    我没见到他呀，我，周一没见到他呀，。
    明天就能见到啊，。
    我明天约他直接吃饭，就这奶茶喝不无所谓了，饭总是要吃的吧。
    是啊，觉得对他这么好，他一定感激
    他放过我吧，他别搞死我就好了。我甚至都觉得好像肯定跟他说啥了，我就懒得猜了，反正也猜不出来。对，见过都知道，见。过都知道，没必要。他爱怎么着怎么着。
    对呀
    爱怎么着怎么着，我现在就只想把你这个单子甩住了。
    这啥福利业ceo。
    富利业。
    用下周。
    富力健ceo来，为啥要我在呢？
    你这个高力，哎，你回头把你这张pt发给我学习一下啊。
    哦，好啊，。
    这么高端的ppt，。
    我昨天我今天跟医生聊天，我感觉一生好有信心。
    我就在想，他到底。
    是给我洗脑，。
    还是。
    给。
    他自己也洗。
    脑，。
    哪个在哪里。啊，是那个采野字吗？野生菌族猴。好海，
    欢迎光临珍烤肉店。原经烤肉和自然原味，
    植啦三小游戏。嗯，芒果大米，
    可以啊，依晨。不是那一晨总不能说不行吧，
    就是他的那个行就是在于，但是我觉得一晨有一个特点，他真的很会他讲的啊，对，他讲的我真，的会信的，你知道吧？
    啊，因为他有逻辑啊，他确实你也讲逻辑。
    对，
    但是依晨的煽动性一般吧啊，。
    不是他的逻辑，我是答应的。这个我不能否认，。
    就是宁波走在正确的路上，这件事儿我不否认啊，你要吃云中鱼，还，是这样菌子，
    我不吃鱼，我不吃鱼就吃，
    我也不吃鱼啊，。
    我们坐里边吧，坐里边啊，坐里边吧，里边安静点，可以啊，或者坐这儿你。
    都行，坐这吧，。
    大一点大一。点，哎呀，。扫码点餐吗？还是可以。扫脸餐，左。
    边单点右边擦餐哦
    """

    let configuration = PunctuationRestorationConfiguration.production
    // 标点字符集, 跟 PuncONNXEngine 一致
    let punctuationSet: Set<Character> = ["，", "。", "？", "、", ",", ".", "?", ";", ":", "！", "；", "："]

    // 模拟生产 flow: ASR 输出无标点, tokens 是纯 CJK 字符
    // 然后把 精修 里的标点"反向"成 Punc 模型输出: 标点前一个 token 位置写上 puncID
    var tokens: [String] = []
    var lastIndexBeforeDot: [(idx: Int, puncID: Int)] = []
    for character in adhd2Fixture {
        let value = String(character)
        if value == "\n" || value == " " { continue }
        if value.utf8.count == 1 {
            // ASCII 字符, 跳过 (精修里的 ASCII 是 "ADHD:", "雅冬:" 之类, 不进 Punc token)
            continue
        }
        // CJK 字符
        if punctuationSet.contains(value) {
            // 任何标点: 记录它前面最近一个 token 位置 + puncID, 但不把标点自身入 token
            if let last = tokens.indices.last {
                let puncID = configuration.puncList.firstIndex(of: value) ?? 0
                lastIndexBeforeDot.append((last, puncID))
            }
            continue  // 标点自身不入 token (生产 ASR 输出无标点)
        }
        tokens.append(value)
    }

    // 构造 puncIDs: 默认 0, 在标点前位置写上对应 puncID
    var puncIDs = Array(repeating: 0, count: tokens.count)
    for entry in lastIndexBeforeDot where entry.idx >= 0 {
        puncIDs[entry.idx] = entry.puncID
    }

    // 记录原始非零位置, 才能在 protectRepetition 后看出"哪些被清"
    let originalPuncIDs = puncIDs
    let originalNonZeroIndices = puncIDs.indices.filter { puncIDs[$0] >= 2 }

    PunctuationRestorationPipeline.protectRepetition(
        puncIDs: &puncIDs, tokens: tokens, configuration: configuration
    )

    // 找出"原本是 3 / 4, 跑完变 0" 的位置 — 这些才是被清掉的
    var actualCleared: [(x: String, y: String, position: Int)] = []
    for index in originalNonZeroIndices where puncIDs[index] == 0 {
        guard index + 1 < tokens.count else { continue }
        actualCleared.append((tokens[index], tokens[index + 1], index))
    }

    // Debug: print first 3 cleared positions 的周围
    print("[DEBUG] originalNonZeroIndices = \(originalNonZeroIndices.prefix(10))...")
    print("[DEBUG] originalNonZeroIndices.count = \(originalNonZeroIndices.count)")
    for entry in actualCleared.prefix(3) {
        let windowStart = max(0, entry.position - 3)
        let windowEnd = min(tokens.count, entry.position + 4)
        let tokenSlice = tokens[windowStart..<windowEnd]
        let tokenWindow = tokenSlice.map { "'\($0)'" }.joined(separator: ",")
        var puncParts: [String] = []
        for k in windowStart..<windowEnd {
            let sym = configuration.symbol(for: puncIDs[k]) ?? "?"
            let origSym = configuration.symbol(for: originalPuncIDs[k]) ?? "?"
            puncParts.append("[\(k)]=\(originalPuncIDs[k])(\(origSym))→\(puncIDs[k])(\(sym))")
        }
        print("  [DEBUG] cleared pos=\(entry.position), tokens[\(windowStart)..\(windowEnd)] = [\(tokenWindow)]")
        print("          \(puncParts.joined(separator: " "))")
    }

    // 期望: L20 (见,过) 和 L51 (一,点) 的"。"被清, 其他位置保留
    // "。" 位置是 puncID[idx] 的 idx, 对应到 tokens[idx]=X, tokens[idx+1]=Y
    // L20 期望清的是 "见" 后面的 "。", 即 tokens[1]="见" 的 puncID[1] 被清
    //    (因为精修 L20 = "对，见过都知道，见。过都知道")
    // L51 期望清的是 "一" 后面的 "。", 即 tokens[4]="一" 的 puncID[4] 被清
    //    (因为精修 L51 = "大一点大一点" + "大" + "一" + "。" + "点")
    let expectedXSet: Set<String> = ["见", "一"]

    let uniqueX = Set(actualCleared.map { $0.x })
    #expect(uniqueX == expectedXSet, "expected X in \(expectedXSet) but got \(uniqueX) — total cleared \(actualCleared.count)")

    // sanity: 不应清 terminal mark 字符当 X
    let anyWrongClearing = actualCleared.contains { token in
        configuration.modelTerminalSymbols.contains(token.x)
    }
    #expect(!anyWrongClearing, "protectRepetition should never clear a punc whose X is a terminal mark")

    // 打印实际结果, 方便 audit
    print("5min 精修 diagnostic: protectRepetition cleared \(actualCleared.count) positions")
    print("total tokens: \(tokens.count), original non-zero positions: \(originalNonZeroIndices.count)")
    for entry in actualCleared {
        let start = max(0, entry.position - 6)
        let end = min(tokens.count, entry.position + 6)
        let ctx = tokens[start..<end].joined()
        let beforePunc = originalPuncIDs[entry.position]
        let afterPunc = puncIDs[entry.position]
        let symbol = configuration.symbol(for: beforePunc) ?? "?"
        print("  cleared pos=\(entry.position) X=\(entry.x) Y=\(entry.y) beforePuncID=\(beforePunc)(\(symbol)) afterPuncID=\(afterPunc) ctx=\(ctx)")
    }

    // 再额外 audit: 列出 5min 中"被清"对应的 精修 context
    let clearedXSet = Set(actualCleared.map { $0.x })
    print("---")
    print("cleared X set: \(clearedXSet.sorted())")
    print("expected X set: \(expectedXSet)")
}
