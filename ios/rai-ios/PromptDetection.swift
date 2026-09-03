import Foundation
import RaiCore

enum PromptKind: Equatable {
    case numberedPermission
    case askUserQuestion
    case unnumberedConfirm
    case planApproval
}

enum PromptSubmitState: Equatable {
    case none
    case unavailable
    case ready
}

enum PromptStepState: Equatable {
    case done
    case current
    case pending
}

struct PromptStep: Equatable, Identifiable {
    let index: Int
    let label: String
    let state: PromptStepState

    var id: Int { index }
}

struct PromptOption: Equatable, Identifiable {
    let digit: Int?
    let label: String
    let description: String?
    let isSelected: Bool
    let isChecked: Bool?
    let isFreeText: Bool
    let isChat: Bool

    init(
        digit: Int?,
        label: String,
        description: String? = nil,
        isSelected: Bool = false,
        isChecked: Bool? = nil,
        isFreeText: Bool = false,
        isChat: Bool = false
    ) {
        self.digit = digit
        self.label = label
        self.description = description
        self.isSelected = isSelected
        self.isChecked = isChecked
        self.isFreeText = isFreeText
        self.isChat = isChat
    }

    var id: String { "\(digit.map(String.init) ?? "-"):\(label)" }
}

struct PromptModel: Equatable {
    let kind: PromptKind
    let question: String?
    let steps: [PromptStep]
    let currentQuestionIndex: Int?
    let options: [PromptOption]
    let multiSelect: Bool
    let submitState: PromptSubmitState
    let showsSelectionFooter: Bool
    /// Exact visible prompt region. This keeps the existing tap race guard.
    let signature: String
    /// Stable while a marker moves or an AskUserQuestion wizard advances.
    let dialogSignature: String
    let instanceKey: PromptInstanceKey

    var selectedOptionIndex: Int? {
        options.firstIndex(where: \.isSelected)
    }

    var isFreeTextEntryActive: Bool {
        kind == .askUserQuestion && submitState == .none && !showsSelectionFooter
    }

    var showsPreviousAction: Bool {
        kind == .askUserQuestion && (currentQuestionIndex ?? 0) > 0
    }

    var actionIdentity: PromptActionIdentity {
        PromptActionIdentity(
            signature: signature,
            dialogSignature: dialogSignature,
            instanceKey: instanceKey,
            questionIndex: currentQuestionIndex
        )
    }

    func withInstanceKey(_ key: PromptInstanceKey) -> PromptModel {
        PromptModel(
            kind: kind,
            question: question,
            steps: steps,
            currentQuestionIndex: currentQuestionIndex,
            options: options,
            multiSelect: multiSelect,
            submitState: submitState,
            showsSelectionFooter: showsSelectionFooter,
            signature: signature,
            dialogSignature: dialogSignature,
            instanceKey: key
        )
    }
}

enum PromptInstanceKey: Equatable {
    case untracked
    case observed(UInt64)
    case request(String, streamGeneration: UInt64)
}

struct PromptActionIdentity: Equatable {
    let signature: String
    let dialogSignature: String
    let instanceKey: PromptInstanceKey
    let questionIndex: Int?
}

enum PromptDetector {
    private static let optionExpression = try! NSRegularExpression(
        pattern: #"^\s*([❯>›])?\s*([1-9][0-9]*)[\.\)]\s+(?:\[([ xX✓✔])\]\s*)?(.+?)\s*$"#
    )
    private static let stepExpression = try! NSRegularExpression(
        pattern: #"([☐□✔✓❯›])\s+(.+?)(?=\s{2,}[☐□✔✓❯›]|\s+→|$)"#
    )

    /// Input is rendered terminal-grid text, never an ANSI byte stream.
    static func detect(in gridText: String, beacon: AgentBeacon? = nil) -> PromptModel? {
        let lines = normalizedLines(gridText)
        let detected = detectAskUserQuestion(lines)
            ?? detectUnnumberedConfirm(lines)
            ?? detectNumberedPrompt(lines)
        guard let detected else { return nil }
        let resolved = resolve(detected, from: beacon)
        guard let requestID = beacon?.requestID, !requestID.isEmpty else { return resolved }
        return resolved.withInstanceKey(.request(requestID, streamGeneration: 0))
    }

    private static func detectAskUserQuestion(_ lines: [String]) -> PromptModel? {
        let footerIndex = lines.lastIndex(where: isAskSelectionFooter)
        if let footerIndex,
           !lines[(footerIndex + 1)..<lines.endIndex].allSatisfy({ trimmed($0).isEmpty }) {
            return nil
        }
        let headerSearchEnd = footerIndex ?? lines.endIndex
        let headerIndex = lines[..<headerSearchEnd].lastIndex(where: isQuestionHeader)
        guard headerIndex != nil || footerIndex != nil else { return nil }

        let parsedSteps = headerIndex.map { parseSteps(lines[$0]) } ?? []
        let parsedStepLabels = parsedSteps.map(\.label)
        let hasSubmitStep = parsedStepLabels.last?.localizedCaseInsensitiveContains("submit")
            == true
        guard parsedSteps.isEmpty
                || hasSubmitStep
                || parsedSteps.count == 1
        else { return nil }

        let endIndex = footerIndex ?? lines.endIndex
        let optionSearchStart = headerIndex.map { $0 + 1 } ?? 0
        let optionRows = parseAskOptionCluster(
            lines: lines,
            range: optionSearchStart..<endIndex
        )
        guard optionRows.count >= 2 else { return nil }
        if !hasSubmitStep,
           (!optionRows.contains(where: { $0.option.isFreeText })
            || !optionRows.contains(where: { $0.option.isChat })) {
            return nil
        }

        let firstOptionLine = optionRows[0].line
        let promptStart = headerIndex
            ?? lines[..<firstOptionLine].lastIndex(where: isRule).map { $0 + 1 }
            ?? max(0, firstOptionLine - 8)
        let questionStart = headerIndex.map { $0 + 1 } ?? promptStart
        let questionRegion = lines[questionStart..<firstOptionLine]
        let questionLines = questionRegion
            .map(trimmed)
            .filter { !$0.isEmpty && !isRule($0) && !$0.hasPrefix("⚠") }
        let question = lastTextBlock(in: questionRegion)
        let isSubmit = hasSubmitStep && questionLines.contains {
            $0.localizedCaseInsensitiveContains("Review your answers")
        } || (hasSubmitStep
            && question?.localizedCaseInsensitiveContains("submit your answers") == true)
        let questionSteps = hasSubmitStep ? Array(parsedSteps.dropLast()) : parsedSteps
        let currentIndex: Int? = isSubmit
            ? nil
            : (questionSteps.count <= 1 ? 0 : inferQuestionIndex(
                question: question,
                steps: questionSteps
            ))
        let submitState: PromptSubmitState = isSubmit
            ? (lines[promptStart..<endIndex].contains {
                $0.localizedCaseInsensitiveContains("not answered all questions")
            } ? .unavailable : .ready)
            : .none
        let stepLabels = parsedStepLabels.isEmpty ? ["Question"] : parsedStepLabels
        let submitIndex = hasSubmitStep ? stepLabels.count - 1 : stepLabels.count
        let steps = stepLabels.enumerated().map { index, label in
            PromptStep(
                index: index,
                label: label,
                state: stepState(
                    index: index,
                    submitIndex: submitIndex,
                    currentQuestionIndex: currentIndex,
                    submitState: submitState
                )
            )
        }
        let regionEnd = footerIndex.map { $0 + 1 } ?? endIndex
        let region = Array(lines[promptStart..<regionEnd])
        return PromptModel(
            kind: .askUserQuestion,
            question: question,
            steps: steps,
            currentQuestionIndex: currentIndex,
            options: optionRows.map(\.option),
            multiSelect: optionRows.contains { $0.option.isChecked != nil },
            submitState: submitState,
            showsSelectionFooter: footerIndex != nil,
            signature: signature(for: region),
            dialogSignature: "ask:" + stepLabels.joined(separator: "|"),
            instanceKey: .untracked
        )
    }

    private static func detectUnnumberedConfirm(_ lines: [String]) -> PromptModel? {
        guard let footerIndex = lines.lastIndex(where: {
            $0.localizedCaseInsensitiveContains("Enter to confirm")
                && $0.localizedCaseInsensitiveContains("Esc to cancel")
        }) else { return nil }

        // A real modal owns the bottom of the live grid. Quoted modal text has
        // Claude's composer or status rows below it and must stay inert.
        guard lines[(footerIndex + 1)..<lines.endIndex].allSatisfy({ trimmed($0).isEmpty })
        else { return nil }

        var optionEnd = footerIndex
        while optionEnd > 0, trimmed(lines[optionEnd - 1]).isEmpty { optionEnd -= 1 }
        var optionStart = optionEnd
        while optionStart > 0, !trimmed(lines[optionStart - 1]).isEmpty {
            optionStart -= 1
        }
        guard optionEnd - optionStart >= 2 else { return nil }

        let optionLines = lines[optionStart..<optionEnd]
        guard let markerLine = optionLines.firstIndex(where: hasSelectionMarker),
              footerIndex - markerLine <= 12
        else { return nil }
        let options = parseUnnumberedOptions(optionLines)
        guard options.count >= 2,
              options.filter(\.isSelected).count == 1
        else { return nil }

        let contextStart = max(0, optionStart - 10)
        let context = Array(lines[contextStart...footerIndex])
        let question = lines[contextStart..<optionStart]
            .map(trimmed)
            .last(where: { $0.contains("?") })
        let text = context.joined(separator: "\n").lowercased()
        guard text.contains("trust")
                || text.contains("allow")
                || text.contains("access")
                || text.contains("proceed")
                || text.contains("warning")
                || text.contains("bypass")
        else { return nil }

        let kind: PromptKind = text.contains("would you like to proceed")
            ? .planApproval
            : .unnumberedConfirm
        return PromptModel(
            kind: kind,
            question: question,
            steps: [],
            currentQuestionIndex: nil,
            options: options,
            multiSelect: false,
            submitState: .none,
            showsSelectionFooter: false,
            signature: signature(for: context),
            dialogSignature: dialogSignature(kind: kind, question: question, options: options),
            instanceKey: .untracked
        )
    }

    private static func detectNumberedPrompt(_ lines: [String]) -> PromptModel? {
        let parsed = parseNumberedOptions(
            lines: lines,
            range: lines.indices,
            includeDescriptions: false
        )

        // Old numbered output often remains above a live prompt. Work from the
        // bottom and consider each compact option cluster independently.
        var clusters: [[ParsedOption]] = []
        for item in parsed {
            if let previous = clusters.last?.last, item.line - previous.line <= 2 {
                clusters[clusters.count - 1].append(item)
            } else {
                clusters.append([item])
            }
        }

        for cluster in clusters.reversed() {
            guard cluster.count >= 2,
                  Set(cluster.compactMap(\.option.digit)).count == cluster.count
            else { continue }
            let first = cluster[0].line
            let last = cluster[cluster.count - 1].line
            let contextStart = max(0, first - 4)
            let contextEnd = min(lines.count - 1, last + 3)
            let region = Array(lines[contextStart...contextEnd])
            let context = region.joined(separator: "\n").lowercased()
            let labels = cluster.map(\.option.label).joined(separator: " ").lowercased()
            let hasPromptControls = context.contains("esc") || context.contains("cancel")
            let isPermissionOrTrust = context.contains("permission")
                || context.contains("allow")
                || context.contains("approve")
                || context.contains("trust")
                || context.contains("proceed")
                || (labels.contains("yes") && labels.contains("no"))
            guard hasPromptControls, isPermissionOrTrust else { continue }

            let question = region.map(trimmed).last(where: { $0.contains("?") })
            let kind: PromptKind = context.contains("would you like to proceed")
                ? .planApproval
                : .numberedPermission
            let options = cluster.map(\.option)
            return PromptModel(
                kind: kind,
                question: question,
                steps: [],
                currentQuestionIndex: nil,
                options: options,
                multiSelect: false,
                submitState: .none,
                showsSelectionFooter: context.contains("enter to select"),
                signature: signature(for: region),
                dialogSignature: dialogSignature(kind: kind, question: question, options: options),
                instanceKey: .untracked
            )
        }
        return nil
    }

    static func signatureMatches(
        _ expected: PromptModel,
        currentGridText: String,
        beacon: AgentBeacon? = nil
    ) -> Bool {
        guard let current = detect(in: currentGridText, beacon: beacon) else { return false }
        return current.signature == expected.signature
            && current.dialogSignature == expected.dialogSignature
            && current.instanceKey == expected.instanceKey
    }

    private static func resolve(_ grid: PromptModel, from beacon: AgentBeacon?) -> PromptModel {
        guard grid.kind == .askUserQuestion,
              let questions = askQuestions(from: beacon),
              !questions.isEmpty,
              beaconStepsMatchGrid(questions: questions, grid: grid)
        else { return grid }

        let currentIndex = grid.submitState == .none ? grid.currentQuestionIndex : nil
        let definition = currentIndex.flatMap { index -> AskQuestion? in
            guard questions.indices.contains(index),
                  grid.steps.indices.contains(index),
                  (grid.steps[index].label == "Question"
                    || textIsCompatible(grid.steps[index].label, questions[index].header)),
                  optionsMatchGrid(question: questions[index], grid: grid)
            else { return nil }
            return questions[index]
        }
        if grid.submitState == .none, definition == nil { return grid }
        var options: [PromptOption] = []
        if let definition {
            for (index, source) in definition.options.enumerated() {
                let visible = grid.options.indices.contains(index) ? grid.options[index] : nil
                options.append(PromptOption(
                    digit: visible?.digit,
                    label: source.label,
                    description: source.description,
                    isSelected: visible?.isSelected ?? false,
                    isChecked: visible?.isChecked
                ))
            }
            options.append(contentsOf: grid.options.dropFirst(definition.options.count))
        } else {
            options = grid.options
        }

        let hasSubmitStep = grid.steps.last?.label.localizedCaseInsensitiveContains("submit")
            == true
        let stepLabels = questions.map(\.header) + (hasSubmitStep ? ["Submit"] : [])
        let submitIndex = hasSubmitStep ? stepLabels.count - 1 : stepLabels.count
        let steps = stepLabels.enumerated().map { index, label in
            PromptStep(
                index: index,
                label: label,
                state: stepState(
                    index: index,
                    submitIndex: submitIndex,
                    currentQuestionIndex: currentIndex,
                    submitState: grid.submitState
                )
            )
        }
        return PromptModel(
            kind: grid.kind,
            question: currentIndex.map { questions[$0].question } ?? grid.question,
            steps: steps,
            currentQuestionIndex: currentIndex,
            options: options,
            multiSelect: grid.multiSelect,
            submitState: grid.submitState,
            showsSelectionFooter: grid.showsSelectionFooter,
            signature: grid.signature,
            dialogSignature: "ask:\(beacon?.sessionID ?? ""):\(beacon?.timestamp ?? 0):"
                + stepLabels.joined(separator: "|"),
            instanceKey: grid.instanceKey
        )
    }

    private struct AskQuestion {
        let question: String
        let header: String
        let options: [(label: String, description: String?)]
        let multiSelect: Bool
    }

    private static func askQuestions(from beacon: AgentBeacon?) -> [AskQuestion]? {
        guard beacon?.event == "PreToolUse",
              beacon?.toolName == "AskUserQuestion",
              case let .object(input)? = beacon?.toolInput,
              case let .array(values)? = input["questions"]
        else { return nil }

        let questions = values.compactMap { value -> AskQuestion? in
            guard case let .object(object) = value,
                  case let .string(question)? = object["question"],
                  case let .string(header)? = object["header"],
                  case let .array(rawOptions)? = object["options"],
                  case let .bool(multiSelect)? = object["multiSelect"]
            else { return nil }
            let options = rawOptions.compactMap { raw -> (String, String?)? in
                guard case let .object(option) = raw,
                      case let .string(label)? = option["label"]
                else { return nil }
                let description: String?
                if case let .string(value)? = option["description"] {
                    description = value
                } else {
                    description = nil
                }
                return (label, description)
            }
            guard !options.isEmpty else { return nil }
            return AskQuestion(
                question: question,
                header: header,
                options: options,
                multiSelect: multiSelect
            )
        }
        return questions.count == values.count ? questions : nil
    }

    private struct ParsedOption {
        let line: Int
        let option: PromptOption
    }

    /// Keep only the menu cluster which contains Claude's selection marker.
    /// A numbered line in the question must never become an answer button.
    private static func parseAskOptionCluster(
        lines: [String],
        range: Range<Int>
    ) -> [ParsedOption] {
        let candidates = range.compactMap { index in
            parseNumberedOption(lines[index]).map { ParsedOption(line: index, option: $0) }
        }
        guard let selected = candidates.firstIndex(where: { $0.option.isSelected }) else {
            return []
        }

        var start = selected
        while start > 0,
              !hasBlankLine(
                  lines: lines,
                  between: candidates[start - 1].line,
                  and: candidates[start].line
              ) {
            start -= 1
        }
        var end = selected + 1
        while end < candidates.count,
              !hasBlankLine(
                  lines: lines,
                  between: candidates[end - 1].line,
                  and: candidates[end].line
              ) {
            end += 1
        }

        let firstLine = candidates[start].line
        let lastLine = candidates[end - 1].line
        return parseNumberedOptions(
            lines: lines,
            range: firstLine..<min(range.upperBound, lastLine + 2),
            includeDescriptions: true
        )
    }

    private static func hasBlankLine(lines: [String], between first: Int, and second: Int) -> Bool {
        guard second > first + 1 else { return false }
        return lines[(first + 1)..<second].contains { trimmed($0).isEmpty }
    }

    private static func parseNumberedOptions(
        lines: [String],
        range: Range<Int>,
        includeDescriptions: Bool
    ) -> [ParsedOption] {
        var rows: [ParsedOption] = []
        for index in range {
            guard var option = parseNumberedOption(lines[index]) else { continue }
            if includeDescriptions {
                let next = index + 1
                if next < range.upperBound {
                    let candidate = trimmed(lines[next])
                    if !candidate.isEmpty,
                       !isRule(candidate),
                       parseNumberedOption(lines[next]) == nil,
                       !candidate.localizedCaseInsensitiveContains("Enter to select"),
                       !(option.isFreeText && candidate.caseInsensitiveCompare("Submit") == .orderedSame) {
                        option = PromptOption(
                            digit: option.digit,
                            label: option.label,
                            description: candidate,
                            isSelected: option.isSelected,
                            isChecked: option.isChecked,
                            isFreeText: option.isFreeText,
                            isChat: option.isChat
                        )
                    }
                }
            }
            rows.append(ParsedOption(line: index, option: option))
        }
        return rows
    }

    private static func parseNumberedOption(_ line: String) -> PromptOption? {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = optionExpression.firstMatch(in: line, range: range),
              let digitRange = Range(match.range(at: 2), in: line),
              let labelRange = Range(match.range(at: 4), in: line),
              let digit = Int(line[digitRange])
        else { return nil }
        let label = trimmed(String(line[labelRange]))
        guard !label.isEmpty else { return nil }
        let checked: Bool?
        if let markRange = Range(match.range(at: 3), in: line) {
            checked = !trimmed(String(line[markRange])).isEmpty
        } else {
            checked = nil
        }
        return PromptOption(
            digit: digit,
            label: label,
            isSelected: match.range(at: 1).location != NSNotFound,
            isChecked: checked,
            isFreeText: isInputOption(label),
            isChat: label.localizedCaseInsensitiveContains("chat about this")
        )
    }

    private static func parseUnnumberedOptions(
        _ lines: ArraySlice<String>
    ) -> [PromptOption] {
        let markers = ["❯", ">", "›"]
        let rows = lines.compactMap { line -> (text: String, indent: Int, marker: String?)? in
            let value = trimmed(line)
            guard !value.isEmpty else { return nil }
            let marker = markers.first(where: { value.hasPrefix($0) })
            let text = marker.map { trimmed(String(value.dropFirst($0.count))) } ?? value
            guard !text.isEmpty else { return nil }
            return (text, line.prefix(while: { $0 == " " || $0 == "\t" }).count, marker)
        }
        guard let optionIndent = rows.filter({ $0.marker == nil }).map(\.indent).min() else {
            return []
        }

        var grouped: [(label: String, selected: Bool)] = []
        for row in rows {
            if row.marker != nil || row.indent <= optionIndent {
                grouped.append((row.text, row.marker != nil))
            } else if !grouped.isEmpty {
                grouped[grouped.count - 1].label += " " + row.text
            }
        }
        return grouped.map { row in
            PromptOption(
                digit: nil,
                label: row.label,
                isSelected: row.selected,
                isFreeText: isInputOption(row.label)
            )
        }
    }

    private static func hasSelectionMarker(_ line: String) -> Bool {
        let value = trimmed(line)
        return value.hasPrefix("❯") || value.hasPrefix(">") || value.hasPrefix("›")
    }

    private static func isInputOption(_ label: String) -> Bool {
        label.localizedCaseInsensitiveContains("type something")
            || label.localizedCaseInsensitiveContains("keep planning")
    }

    private struct ParsedStep {
        let label: String
        let isCurrent: Bool
    }

    private static func parseSteps(_ line: String) -> [ParsedStep] {
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return stepExpression.matches(in: line, range: range).compactMap { match in
            guard let markerRange = Range(match.range(at: 1), in: line),
                  let labelRange = Range(match.range(at: 2), in: line)
            else { return nil }
            let marker = String(line[markerRange])
            return ParsedStep(
                label: trimmed(String(line[labelRange])),
                isCurrent: marker == "❯" || marker == "›"
            )
        }
    }

    private static func inferQuestionIndex(question: String?, steps: [ParsedStep]) -> Int? {
        if let marked = steps.firstIndex(where: \.isCurrent) { return marked }
        guard let question else { return nil }
        let normalizedQuestion = normalized(question)
        if let match = steps.firstIndex(where: {
            let header = normalized($0.label)
            return !header.isEmpty && normalizedQuestion.contains(header)
        }) {
            return match
        }
        return nil
    }

    private static func beaconStepsMatchGrid(
        questions: [AskQuestion],
        grid: PromptModel
    ) -> Bool {
        let hasSubmitStep = grid.steps.last?.label.localizedCaseInsensitiveContains("submit")
            == true
        let visible = (hasSubmitStep ? grid.steps.dropLast() : grid.steps[...]).map(\.label)
        guard visible.count == questions.count else { return false }
        return zip(visible, questions.map(\.header)).allSatisfy {
            $0.0 == "Question" || textIsCompatible($0.0, $0.1)
        }
    }

    private static func optionsMatchGrid(question: AskQuestion, grid: PromptModel) -> Bool {
        guard grid.options.count >= question.options.count else { return false }
        return zip(grid.options, question.options).allSatisfy {
            textIsCompatible($0.0.label, $0.1.label)
        }
    }

    private static func textIsCompatible(_ visible: String, _ source: String) -> Bool {
        let visible = normalized(visible)
        let source = normalized(source)
        guard !visible.isEmpty, !source.isEmpty else { return false }
        return source.hasPrefix(visible)
    }

    private static func lastTextBlock(in lines: ArraySlice<String>) -> String? {
        var current: [String] = []
        var last: [String] = []
        for line in lines {
            let value = trimmed(line)
            if value.isEmpty || isRule(value) || value.hasPrefix("⚠") {
                if !current.isEmpty {
                    last = current
                    current = []
                }
            } else {
                current.append(value)
            }
        }
        if !current.isEmpty { last = current }
        return last.isEmpty ? nil : last.joined(separator: " ")
    }

    private static func stepState(
        index: Int,
        submitIndex: Int,
        currentQuestionIndex: Int?,
        submitState: PromptSubmitState
    ) -> PromptStepState {
        if submitState != .none {
            if index == submitIndex { return .current }
            return submitState == .ready ? .done : .pending
        }
        guard let currentQuestionIndex else { return .pending }
        if index < currentQuestionIndex { return .done }
        if index == currentQuestionIndex { return .current }
        return .pending
    }

    private static func dialogSignature(
        kind: PromptKind,
        question: String?,
        options: [PromptOption]
    ) -> String {
        "\(kind):\(question ?? ""):\(options.map(\.label).joined(separator: "|"))"
    }

    private static func isQuestionHeader(_ line: String) -> Bool {
        let value = trimmed(line)
        if value.hasPrefix("←") && value.hasSuffix("→")
            && value.localizedCaseInsensitiveContains("submit") {
            return true
        }
        let markers = ["☐", "□", "✔", "✓"]
        return markers.contains(where: value.hasPrefix) && parseSteps(line).count == 1
    }

    private static func isAskSelectionFooter(_ line: String) -> Bool {
        line.localizedCaseInsensitiveContains("Enter to select")
            && line.localizedCaseInsensitiveContains("Esc to cancel")
    }

    private static func isRule(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { $0 == "─" || $0 == "-" }
    }

    private static func signature(for lines: [String]) -> String {
        lines.map(trimmed).joined(separator: "\n")
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }
}

enum PromptChoreographyResult: Equatable {
    case sendKey(String)
    case wait
    case complete
    case refused
}

struct PromptPendingToggle: Equatable {
    let dialogSignature: String
    let instanceKey: PromptInstanceKey
    let questionIndex: Int?
    let optionID: String
    let wanted: Bool
}

struct PromptChoreography {
    enum Action: Equatable {
        case choose(optionID: String)
        case toggle(optionID: String)
        case advance
        case retreat
        case submit
    }

    private enum Phase: Equatable {
        case ready
        case awaitingPosition(
            expected: Int,
            target: Int,
            previous: Int?,
            question: Int?,
            frame: String
        )
        case awaitingToggle(expected: Bool, option: Int, frame: String)
        case awaitingNavigation(from: Int, direction: Int, frame: String)
        case awaitingCompletion(question: Int?, allowsSameQuestion: Bool, frame: String)
        case finished
    }

    static let responseWindow: TimeInterval = 4
    static let maximumKeys = 16

    let action: Action
    let renderedIdentity: PromptActionIdentity
    let dialogSignature: String
    let kind: PromptKind
    let expiresAt: TimeInterval
    let selectionQuestion: String?
    let selectionOptionIDs: [String]
    private var phase: Phase = .ready
    private(set) var keyCount = 0

    var pendingToggle: PromptPendingToggle? {
        guard case let .awaitingToggle(expected, option, _) = phase,
              selectionOptionIDs.indices.contains(option)
        else { return nil }
        return PromptPendingToggle(
            dialogSignature: dialogSignature,
            instanceKey: renderedIdentity.instanceKey,
            questionIndex: renderedIdentity.questionIndex,
            optionID: selectionOptionIDs[option],
            wanted: expected
        )
    }

    func isExpired(at now: TimeInterval) -> Bool {
        now > expiresAt
    }

    init(action: Action, prompt: PromptModel, now: TimeInterval) {
        self.action = action
        renderedIdentity = prompt.actionIdentity
        dialogSignature = prompt.dialogSignature
        kind = prompt.kind
        expiresAt = now + Self.responseWindow
        selectionQuestion = prompt.question
        selectionOptionIDs = prompt.options.map(\.id)
    }

    mutating func next(prompt: PromptModel?, now: TimeInterval) -> PromptChoreographyResult {
        guard phase != .finished, now <= expiresAt, keyCount < Self.maximumKeys else {
            phase = .finished
            return .refused
        }
        if prompt == nil {
            if case let .awaitingCompletion(_, allowsSameQuestion, _) = phase {
                phase = .finished
                return allowsSameQuestion ? .refused : .complete
            }
            phase = .finished
            return .refused
        }
        guard let prompt else { return .refused }

        if prompt.dialogSignature != dialogSignature
            || prompt.instanceKey != renderedIdentity.instanceKey {
            phase = .finished
            return .refused
        }

        switch phase {
        case .ready, .awaitingPosition, .awaitingToggle:
            guard prompt.question == selectionQuestion,
                  prompt.options.map(\.id) == selectionOptionIDs
            else {
                phase = .finished
                return .refused
            }
        case .awaitingNavigation, .awaitingCompletion, .finished:
            break
        }

        switch phase {
        case .ready:
            guard prompt.actionIdentity == renderedIdentity else {
                phase = .finished
                return .refused
            }
            return start(with: prompt)
        case let .awaitingPosition(expected, target, previous, question, frame):
            guard prompt.signature != frame else { return .wait }
            guard prompt.selectedOptionIndex == expected,
                  prompt.selectedOptionIndex != previous,
                  prompt.currentQuestionIndex == question
            else {
                phase = .finished
                return .refused
            }
            if expected == target {
                return reached(option: target, in: prompt)
            }
            return move(to: target, in: prompt)
        case let .awaitingToggle(expected, option, frame):
            guard prompt.signature != frame else { return .wait }
            guard prompt.options.indices.contains(option),
                  prompt.options[option].isChecked == expected
            else {
                phase = .finished
                return .refused
            }
            phase = .finished
            return .complete
        case let .awaitingNavigation(from, direction, frame):
            guard prompt.signature != frame else { return .wait }
            let reachedQuestion = prompt.currentQuestionIndex == from + direction
            let reachedSubmit = direction > 0
                && prompt.currentQuestionIndex == nil
                && prompt.submitState != .none
            guard reachedQuestion || reachedSubmit else {
                phase = .finished
                return .refused
            }
            phase = .finished
            return .complete
        case let .awaitingCompletion(question, allowsSameQuestion, frame):
            guard prompt.signature != frame else { return .wait }
            if kind == .askUserQuestion,
               prompt.currentQuestionIndex == question,
               prompt.submitState == .none,
               !allowsSameQuestion {
                phase = .finished
                return .refused
            }
            phase = .finished
            return .complete
        case .finished:
            return .refused
        }
    }

    private mutating func start(with prompt: PromptModel) -> PromptChoreographyResult {
        switch action {
        case let .choose(optionID), let .toggle(optionID):
            guard let target = prompt.options.firstIndex(where: { $0.id == optionID }) else {
                phase = .finished
                return .refused
            }
            return move(to: target, in: prompt)
        case .advance:
            guard prompt.kind == .askUserQuestion,
                  prompt.submitState == .none,
                  let current = prompt.currentQuestionIndex,
                  !prompt.multiSelect || prompt.options.contains(where: { $0.isChecked == true })
            else {
                phase = .finished
                return .refused
            }
            phase = .awaitingNavigation(from: current, direction: 1, frame: prompt.signature)
            return send("Tab")
        case .retreat:
            guard prompt.kind == .askUserQuestion,
                  prompt.submitState == .none,
                  let current = prompt.currentQuestionIndex,
                  current > 0
            else {
                phase = .finished
                return .refused
            }
            phase = .awaitingNavigation(from: current, direction: -1, frame: prompt.signature)
            return send("Left")
        case .submit:
            guard prompt.kind == .askUserQuestion,
                  prompt.submitState == .ready,
                  let target = prompt.options.firstIndex(where: {
                      $0.label.localizedCaseInsensitiveContains("submit")
                  })
            else {
                phase = .finished
                return .refused
            }
            return move(to: target, in: prompt)
        }
    }

    private mutating func move(
        to target: Int,
        in prompt: PromptModel
    ) -> PromptChoreographyResult {
        if prompt.selectedOptionIndex == target {
            return reached(option: target, in: prompt)
        }
        if let digit = prompt.options[target].digit {
            phase = .awaitingPosition(
                expected: target,
                target: target,
                previous: prompt.selectedOptionIndex,
                question: prompt.currentQuestionIndex,
                frame: prompt.signature
            )
            return send(String(digit))
        }
        guard let selected = prompt.selectedOptionIndex else {
            phase = .finished
            return .refused
        }
        let next = selected + (target > selected ? 1 : -1)
        phase = .awaitingPosition(
            expected: next,
            target: target,
            previous: selected,
            question: prompt.currentQuestionIndex,
            frame: prompt.signature
        )
        return send(target > selected ? "Down" : "Up")
    }

    private mutating func reached(
        option index: Int,
        in prompt: PromptModel
    ) -> PromptChoreographyResult {
        switch action {
        case .toggle:
            guard prompt.multiSelect, let checked = prompt.options[index].isChecked else {
                phase = .finished
                return .refused
            }
            phase = .awaitingToggle(
                expected: !checked,
                option: index,
                frame: prompt.signature
            )
            return send("Space")
        case .choose:
            if prompt.options[index].isFreeText {
                if prompt.kind == .askUserQuestion, !prompt.showsSelectionFooter {
                    phase = .finished
                    return .complete
                }
                return sendEnter(for: prompt, allowsSameQuestion: true)
            }
            return sendEnter(for: prompt)
        case .submit:
            return sendEnter(for: prompt)
        case .advance, .retreat:
            phase = .finished
            return .refused
        }
    }

    private mutating func sendEnter(
        for prompt: PromptModel,
        allowsSameQuestion: Bool = false
    ) -> PromptChoreographyResult {
        phase = .awaitingCompletion(
            question: prompt.currentQuestionIndex,
            allowsSameQuestion: allowsSameQuestion,
            frame: prompt.signature
        )
        return send("Enter")
    }

    private mutating func send(_ key: String) -> PromptChoreographyResult {
        keyCount += 1
        return .sendKey(key)
    }
}
