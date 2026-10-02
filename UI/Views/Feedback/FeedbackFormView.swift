import SwiftUI
import Dispatch

// MARK: - Feedback Form View

public struct FeedbackFormView: View {

    // MARK: - Properties

    @StateObject private var viewModel: FeedbackViewModel
    @EnvironmentObject private var coordinatorWrapper: AppCoordinatorWrapper
    @Environment(\.dismiss) private var dismiss

    private let launchContext: FeedbackLaunchContext?
    private let onSuccessfulSubmit: (() -> Void)?

    @FocusState private var focusedField: FocusedField?
    @State private var escapeKeyMonitor: Any?
    @State private var sendingPulseExpanded = false
    @State private var successIconScale: CGFloat = 0.72
    @State private var successIconOpacity = 0.0
    @State private var successBurstScale: CGFloat = 0.72
    @State private var successBurstOpacity = 0.0
    @State private var successTextOpacity = 0.0
    @State private var successTextOffset: CGFloat = 14
    @State private var measuredFormContentHeight: CGFloat = 0
    @State private var measuredFormFooterHeight: CGFloat = 0
    @State private var feedbackWindowNumber: Int?
    @State private var keyboardFocusTarget: KeyboardFocusTarget = .description
    @State private var suppressAutomaticFocusScroll = true
    @StateObject private var scrollLatch = HoverLatchedScrollMonitor<ScrollTarget>(
        hoverPriority: [.details],
        defaultTarget: .outer
    )

    private enum FocusedField {
        case email
        case description
    }

    private enum ScrollTarget {
        case outer
        case details
    }

    private enum KeyboardFocusTarget: Hashable {
        case email
        case description
        case details
        case diagnosticSection(DiagnosticInfo.SectionID)
        case attachScreenshot
        case downloadReport
        case submit
    }

    private enum PresentationState: Equatable {
        case form
        case submitting
        case failure
        case success
    }

    private enum FormContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    private enum FormFooterHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0

        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    public init(
        launchContext: FeedbackLaunchContext? = nil,
        onSuccessfulSubmit: (() -> Void)? = nil
    ) {
        self.launchContext = launchContext
        self.onSuccessfulSubmit = onSuccessfulSubmit
        _viewModel = StateObject(wrappedValue: FeedbackViewModel(launchContext: launchContext))
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            backgroundView
            contentView
        }
        .frame(width: 480, height: containerHeight)
        .clipped()
        .animation(.spring(response: 0.42, dampingFraction: 0.88), value: presentationState)
        .background(
            FeedbackWindowObserver { windowNumber in
                feedbackWindowNumber = windowNumber
                if viewModel.showDiagnosticsDetail {
                    installScrollMonitorIfNeeded()
                }
            }
        )
        .onAppear {
            suppressAutomaticFocusScroll = true
            viewModel.setCoordinator(coordinatorWrapper)
            setupEscapeKeyHandler()
            applyInitialFocusIfNeeded()
        }
        .onDisappear {
            removeEscapeKeyHandler()
            removeScrollMonitor()
            viewModel.teardown()
        }
        .onChange(of: viewModel.isSubmitting) { isSubmitting in
            guard isSubmitting else { return }
            beginSendingAnimations()
        }
        .onChange(of: viewModel.completionState) { completionState in
            guard completionState != nil else { return }
            playSuccessAnimation()
        }
        .onChange(of: viewModel.isSubmitted) { isSubmitted in
            guard isSubmitted else { return }
            onSuccessfulSubmit?()
        }
        .onChange(of: focusedField) { newValue in
            switch newValue {
            case .email:
                keyboardFocusTarget = .email
            case .description:
                keyboardFocusTarget = .description
            case nil:
                break
            }
        }
        .onChange(of: viewModel.feedbackType) { _ in
            ensureKeyboardFocusIsValid()
        }
        .onChange(of: viewModel.showDiagnosticsDetail) { isExpanded in
            ensureKeyboardFocusIsValid()
            if isExpanded {
                installScrollMonitorIfNeeded()
            } else {
                removeScrollMonitor()
            }
        }
    }

    // MARK: - Escape Key Handling

    @ViewBuilder
    private var contentView: some View {
        switch presentationState {
        case .form:
            formView
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .submitting:
            submittingView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        case .failure:
            submissionFailureView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        case .success:
            successView
                .transition(.opacity.combined(with: .scale(scale: 1.02)))
        }
    }

    private var presentationState: PresentationState {
        if viewModel.hasSuccessfulCompletion {
            return .success
        }
        if viewModel.isSubmitting {
            return .submitting
        }
        if viewModel.hasSubmissionFailure {
            return .failure
        }
        return .form
    }

    private var containerHeight: CGFloat {
        switch presentationState {
        case .form:
            let measuredHeight = measuredFormContentHeight + measuredFormFooterHeight
            return min(540, max(0, measuredHeight))
        case .submitting, .failure, .success:
            return 540
        }
    }

    private func setupEscapeKeyHandler() {
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            if event.keyCode == 53 { // Escape key
                if viewModel.isSubmitting {
                    return nil
                }
                dismiss()
                return nil // Consume the event
            }

            if presentationState == .form {
                if handleCommandSubmitShortcut(event) {
                    return nil
                }
                if handleTabNavigation(event) {
                    return nil
                }
                if handleFocusedControlActivation(event) {
                    return nil
                }
            }
            return event
        }
    }

    private func removeEscapeKeyHandler() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
    }

    private var isOuterScrollDisabled: Bool {
        viewModel.showDiagnosticsDetail && scrollLatch.latchedTarget == .details
    }

    private var isDiagnosticsScrollEnabled: Bool {
        switch scrollLatch.latchedTarget {
        case .outer:
            return false
        case .details, .none:
            return true
        }
    }

    private func installScrollMonitorIfNeeded() {
        guard viewModel.showDiagnosticsDetail else { return }

        scrollLatch.installMonitorIfNeeded { event in
            guard let feedbackWindowNumber else { return false }
            return event.window?.windowNumber == feedbackWindowNumber
        }
    }

    private func removeScrollMonitor() {
        scrollLatch.removeMonitor()
    }

    private func applyInitialFocusIfNeeded() {
        let initialTarget: KeyboardFocusTarget = launchContext?.preferredFocusField == .email ? .email : .description
        DispatchQueue.main.async {
            self.setKeyboardFocus(initialTarget)
            DispatchQueue.main.async {
                self.suppressAutomaticFocusScroll = false
            }
        }
    }

    private var formKeyboardOrder: [KeyboardFocusTarget] {
        var order: [KeyboardFocusTarget] = [
            .email,
            .description,
            .details,
        ]
        if viewModel.showDiagnosticsDetail {
            order.append(contentsOf: viewModel.diagnosticSections.map {
                .diagnosticSection($0.id)
            })
        }
        order.append(.attachScreenshot)
        order.append(.downloadReport)
        order.append(.submit)
        return order
    }

    private func ensureKeyboardFocusIsValid() {
        guard presentationState == .form else { return }
        if !formKeyboardOrder.contains(keyboardFocusTarget),
           let fallback = formKeyboardOrder.first {
            setKeyboardFocus(fallback)
        }
    }

    private func setKeyboardFocus(_ target: KeyboardFocusTarget) {
        keyboardFocusTarget = target
        switch target {
        case .email:
            focusedField = .email
        case .description:
            focusedField = .description
        case .details, .diagnosticSection(_), .attachScreenshot, .downloadReport, .submit:
            focusedField = nil
        }
    }

    private func moveKeyboardFocus(forward: Bool) {
        let order = formKeyboardOrder
        guard !order.isEmpty else { return }

        guard let currentIndex = order.firstIndex(of: keyboardFocusTarget) else {
            setKeyboardFocus(order[0])
            return
        }

        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % order.count
        } else {
            nextIndex = (currentIndex - 1 + order.count) % order.count
        }
        setKeyboardFocus(order[nextIndex])
    }

    private func handleTabNavigation(_ event: NSEvent) -> Bool {
        guard event.keyCode == 48 else { return false } // Tab
        guard !event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.option),
              !event.modifierFlags.contains(.control) else {
            return false
        }

        moveKeyboardFocus(forward: !event.modifierFlags.contains(.shift))
        return true
    }

    private func handleCommandSubmitShortcut(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return false }
        guard event.modifierFlags.contains(.command) else { return false }
        guard viewModel.canSubmit else { return true }

        Task { await viewModel.submit() }
        return true
    }

    private func handleFocusedControlActivation(_ event: NSEvent) -> Bool {
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isReturn else { return false }
        guard !event.modifierFlags.contains(.command) else { return false }

        switch keyboardFocusTarget {
        case .details:
            toggleDiagnosticsDetail()
            return true
        case .diagnosticSection(let section):
            viewModel.toggleDiagnosticSection(section)
            return true
        case .attachScreenshot:
            viewModel.selectImageFromFinder()
            return true
        case .downloadReport:
            if viewModel.canExport {
                Task { await viewModel.exportFeedbackReport() }
            }
            return true
        case .submit:
            if viewModel.canSubmit {
                Task { await viewModel.submit() }
            }
            return true
        case .email, .description:
            return false
        }
    }

    private func toggleDiagnosticsDetail() {
        let shouldLoad = !viewModel.showDiagnosticsDetail

        withAnimation(.easeOut(duration: 0.16)) {
            viewModel.showDiagnosticsDetail.toggle()
        }

        guard shouldLoad else { return }

        // Defer loading one runloop so the expanded state renders immediately.
        DispatchQueue.main.async {
            viewModel.loadDiagnosticsIfNeeded()
        }
    }

    private func scrollAnchorTarget(for target: KeyboardFocusTarget) -> KeyboardFocusTarget? {
        switch target {
        case .email, .description, .details, .diagnosticSection(_), .attachScreenshot, .downloadReport:
            return target
        case .submit:
            // Submit is in the fixed footer and already visible.
            return nil
        }
    }

    private func scrollToFocusedControl(_ target: KeyboardFocusTarget, proxy: ScrollViewProxy) {
        guard !suppressAutomaticFocusScroll,
              let anchorTarget = scrollAnchorTarget(for: target) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo(anchorTarget, anchor: .center)
            }
        }
    }

    private func beginSendingAnimations() {
        sendingPulseExpanded = false

        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            sendingPulseExpanded = true
        }
    }

    private func playSuccessAnimation() {
        successIconScale = 0.72
        successIconOpacity = 0
        successBurstScale = 0.72
        successBurstOpacity = 0.42
        successTextOpacity = 0
        successTextOffset = 14

        withAnimation(.spring(response: 0.5, dampingFraction: 0.74)) {
            successIconScale = 1
            successIconOpacity = 1
        }
        withAnimation(.easeOut(duration: 0.7).delay(0.04)) {
            successBurstScale = 1.3
            successBurstOpacity = 0
        }
        withAnimation(.spring(response: 0.48, dampingFraction: 0.84).delay(0.12)) {
            successTextOpacity = 1
            successTextOffset = 0
        }
    }

    // MARK: - Background

    private var backgroundView: some View {
        Color.retracePage
    }

    // MARK: - Form View

    private var formView: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Header
                        header

                        // Feedback Type Picker
                        feedbackTypeSection

                        // Email
                        emailSection
                            .id(KeyboardFocusTarget.email)

                        // Description
                        descriptionSection
                            .id(KeyboardFocusTarget.description)

                        diagnosticsSection
                            .id(KeyboardFocusTarget.details)

                        // Image Attachment
                        imageAttachmentSection
                            .id(KeyboardFocusTarget.attachScreenshot)

                        // Manual export fallback directly under screenshot attachment
                        offlineExportCard
                            .id(KeyboardFocusTarget.downloadReport)

                        // Error
                        if let error = viewModel.error {
                            errorBanner(error)
                        }
                    }
                    .padding(20)
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: FormContentHeightKey.self,
                                    value: geometry.size.height
                                )
                        }
                    )
                }
                .scrollDisabled(isOuterScrollDisabled)
                .onChange(of: keyboardFocusTarget) { newValue in
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(newValue, proxy: proxy)
                }
                .onAppear {
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(keyboardFocusTarget, proxy: proxy)
                }
                .onChange(of: viewModel.showDiagnosticsDetail) { _ in
                    guard presentationState == .form else { return }
                    scrollToFocusedControl(keyboardFocusTarget, proxy: proxy)
                }
            }
            actionButtons
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 20)
                .background(Color.retracePage)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.retraceBorder)
                        .frame(height: 1)
                        .allowsHitTesting(false)
                }
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: FormFooterHeightKey.self,
                        value: geometry.size.height
                    )
                }
            )
        }
        .onPreferenceChange(FormContentHeightKey.self) { newValue in
            if abs(newValue - measuredFormContentHeight) > 0.5 {
                measuredFormContentHeight = newValue
            }
        }
        .onPreferenceChange(FormFooterHeightKey.self) { newValue in
            if abs(newValue - measuredFormFooterHeight) > 0.5 {
                measuredFormFooterHeight = newValue
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.retraceAccentWash)
                        .frame(width: 36, height: 36)

                    RetraceSymbol("bubble.left.and.bubble.right.fill", size: 14, weight: .semibold)
                        .foregroundColor(.retraceAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share Feedback")
                        .font(.retraceTitle2)
                        .foregroundColor(.retraceInk)

                    Text("Help us improve Retrace")
                        .font(.retraceMeta)
                        .foregroundColor(.retraceMuted)
                }
            }

            Spacer()

            Button(action: { dismiss() }) {
                RetraceSymbol("xmark", size: 10, weight: .semibold)
                    .foregroundColor(.retraceInk2)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(Color.retraceSurfaceSunken)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(Color.retraceBorderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    // MARK: - Feedback Type Section

    private var feedbackTypeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type")
                .font(.retraceLabel)
                .retraceLabelTracking()
                .foregroundColor(.retraceInk2)

            HStack(spacing: 8) {
                ForEach(FeedbackType.allCases) { type in
                    feedbackTypeButton(type)
                }
            }
        }
    }

    private func feedbackTypeButton(_ type: FeedbackType) -> some View {
        let isSelected = viewModel.feedbackType == type

        return Button(action: { viewModel.setFeedbackType(type) }) {
            HStack(spacing: 5) {
                RetraceSymbol(type.icon, size: 11, weight: .medium)
                Text(type.shortLabel)
                    .font(.retraceCaption)
                    .lineLimit(1)
            }
            .foregroundColor(isSelected ? .retraceInk : .retraceInk2)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .fill(isSelected ? Color.retraceAccentWash : Color.retraceSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                    .stroke(isSelected ? Color.retraceAccent : Color.retraceBorderStrong, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - Email Section

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Email")
                .font(.retraceLabel)
                .retraceLabelTracking()
                .foregroundColor(.retraceInk2)

            TextField("your@email.com", text: $viewModel.email)
                .font(.retraceCallout)
                .foregroundColor(.retraceInk)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: .email)
                .onTapGesture {
                    keyboardFocusTarget = .email
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(
                            viewModel.showEmailError
                                ? Color.retraceCritical
                                : (keyboardFocusTarget == .email ? Color.retraceAccent : Color.retraceBorderStrong),
                            lineWidth: (keyboardFocusTarget == .email && !viewModel.showEmailError) ? 2 : 1
                        )
                )

            if viewModel.showEmailError {
                Text("Please enter a valid email address")
                    .font(.retraceCaption)
                    .foregroundColor(.retraceCritical)
            }
        }
    }

    // MARK: - Description Section

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.retraceLabel)
                .retraceLabelTracking()
                .foregroundColor(.retraceInk2)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $viewModel.description)
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .description)
                    .onTapGesture {
                        keyboardFocusTarget = .description
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(Color.retraceSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(
                                keyboardFocusTarget == .description
                                    ? Color.retraceAccent
                                    : Color.retraceBorderStrong,
                                lineWidth: keyboardFocusTarget == .description ? 2 : 1
                            )
                    )

                if viewModel.description.isEmpty {
                    Text(viewModel.feedbackType.placeholder)
                        .font(.retraceCallout)
                        .foregroundColor(.retraceMuted)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 90)
        }
    }

    // MARK: - Diagnostics Section

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 6) {
                    RetraceSymbol("doc.text.magnifyingglass", size: 12, weight: .medium)
                        .foregroundColor(.retraceInk2)
                    Text("What's Included")
                        .font(.retraceCaptionBold)
                        .foregroundColor(.retraceInk)
                }

                Spacer()

                Button(action: {
                    keyboardFocusTarget = .details
                    toggleDiagnosticsDetail()
                }) {
                    HStack(spacing: 4) {
                        Text(viewModel.showDiagnosticsDetail ? "Hide" : "Details")
                            .font(.retraceCaption2Medium)
                        RetraceSymbol(viewModel.showDiagnosticsDetail ? "chevron.up" : "chevron.down", size: 11, weight: .semibold)
                    }
                    .foregroundColor(keyboardFocusTarget == .details ? .retraceInk : .retraceAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(keyboardFocusTarget == .details ? Color.retraceAccentWash : Color.clear)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(
                                keyboardFocusTarget == .details
                                    ? Color.retraceAccent
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            if viewModel.includesLogsInDiagnostics || viewModel.hasSelectedDiagnosticSections {
                HStack(spacing: 12) {
                    diagnosticChip(icon: "app.badge", text: "Version")
                    diagnosticChip(icon: "desktopcomputer", text: "Device")
                    diagnosticChip(icon: "cylinder", text: "Stats")
                    diagnosticChip(icon: "memorychip", text: "Memory")
                    if viewModel.includesLogsInDiagnostics {
                        diagnosticChip(icon: "doc.text", text: "Logs")
                    }
                }
            }

            if viewModel.includesLogsInDiagnostics {
                Text("Bug reports include recent logs plus a hierarchical Retrace memory summary from the system monitor sampler.")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            } else if viewModel.hasSelectedDiagnosticSections {
                Text("Optional diagnostics are selected for this message. Expand details to exclude anything you don't want to share.")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            } else {
                Text("Feature requests and questions send only your written message and any screenshot by default. Expand details to opt in to diagnostics.")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }

            // Expanded details (lazy loaded)
            if viewModel.showDiagnosticsDetail {
                Divider()
                    .background(Color.retraceBorder)

                if viewModel.diagnostics != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Uncheck any section you don't want included with this report.")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)

                        if viewModel.excludedDiagnosticSectionCount > 0 {
                            Text("\(viewModel.excludedDiagnosticSectionCount) section\(viewModel.excludedDiagnosticSectionCount == 1 ? "" : "s") currently excluded")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceMuted)
                        }

                        ScrollView(showsIndicators: true) {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(viewModel.diagnosticSections) { section in
                                    diagnosticSectionCard(section)
                                        .id(KeyboardFocusTarget.diagnosticSection(section.id))
                                }
                            }
                            .padding(8)
                        }
                        .scrollDisabled(!isDiagnosticsScrollEnabled)
                        .frame(height: 280)
                        .background(Color.retraceSurfaceSunken)
                        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        .onHover { hovering in
                            scrollLatch.updateHoveredTarget(.details, isHovering: hovering)
                        }

                        if !viewModel.hasSelectedDiagnosticSections {
                            Text("No diagnostics will be attached beyond your written description and any screenshot you add.")
                                .font(.retraceCaption2)
                                .foregroundColor(.retraceMuted)
                        }
                    }
                } else {
                    HStack {
                        SpinnerView(size: 16, lineWidth: 2)
                        Text("Loading diagnostics...")
                            .font(.retraceCaption2)
                            .foregroundColor(.retraceInk2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .animation(.easeOut(duration: 0.16), value: viewModel.showDiagnosticsDetail)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .retraceElevation(.sm)
    }

    private func diagnosticChip(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            RetraceSymbol(icon, size: 10)
            Text(text)
                .font(.retraceTiny)
        }
        .foregroundColor(.retraceInk2)
    }

    private func diagnosticSectionCard(_ section: DiagnosticInfo.SectionSummary) -> some View {
        let isIncluded = viewModel.isDiagnosticSectionIncluded(section.id)
        let isFocused = keyboardFocusTarget == .diagnosticSection(section.id)

        return VStack(alignment: .leading, spacing: 10) {
            Button(action: {
                keyboardFocusTarget = .diagnosticSection(section.id)
                viewModel.toggleDiagnosticSection(section.id)
            }) {
                HStack(alignment: .top, spacing: 10) {
                    RetraceSymbol(isIncluded ? "checkmark.square.fill" : "square", size: 14, weight: .semibold)
                        .foregroundColor(isIncluded ? .retraceAccent : .retraceInk2)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(section.title)
                                .font(.retraceCaptionBold)
                                .foregroundColor(.retraceInk)

                            if let countSummary = section.countSummary {
                                Text(countSummary)
                                    .font(.retraceMonoSmall)
                                    .foregroundColor(.retraceInk2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule(style: .continuous).fill(Color.retraceSurfaceSunken))
                            }
                        }

                        Text(section.reason)
                            .font(.retraceMeta)
                            .foregroundColor(.retraceMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Text(isIncluded ? "Included" : "Excluded")
                        .font(.retraceLabel)
                        .foregroundColor(isIncluded ? .retraceInk : .retraceInk2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(isIncluded ? Color.retraceAccentWash : Color.retraceSurfaceSunken)
                        )
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isIncluded ? .isSelected : [])
            .accessibilityValue(isIncluded ? "Included" : "Excluded")

            Text(section.preview)
                .font(.retraceMonoSmall)
                .foregroundColor(
                    isIncluded
                        ? .retraceInk
                        : .retraceInk2
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurfaceSunken)
                )

            if let previewDisclosure = section.previewDisclosure {
                Text(previewDisclosure)
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                .stroke(
                    isFocused
                        ? Color.retraceAccent
                        : (isIncluded ? Color.retraceBorderStrong : Color.retraceBorder),
                    lineWidth: isFocused ? 2 : 1
                )
        )
    }

    // MARK: - Image Attachment Section

    @State private var isDropTargeted = false

    private var imageAttachmentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = viewModel.attachedImage {
                // Show attached image preview
                HStack(spacing: 10) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: 50)
                        .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                                .stroke(Color.retraceBorder, lineWidth: 1)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Image attached")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceInk)
                        if let data = viewModel.attachedImageData {
                            Text("\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))")
                                .font(.retraceMonoSmall)
                                .foregroundColor(.retraceMuted)
                        }
                    }

                    Spacer()

                    Button(action: { viewModel.removeAttachedImage() }) {
                        RetraceSymbol("xmark.circle.fill", size: 16)
                            .foregroundColor(.retraceInk2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove image")
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(Color.retraceBorder, lineWidth: 1)
                )
            } else {
                // Drop zone / select button
                Button(action: {
                    keyboardFocusTarget = .attachScreenshot
                    viewModel.selectImageFromFinder()
                }) {
                    HStack(spacing: 8) {
                        RetraceSymbol("photo.badge.plus", size: 12)
                            .foregroundColor(.retraceInk2)
                        Text("Attach image")
                            .font(.retraceCaption)
                            .foregroundColor(.retraceInk2)
                        Spacer()
                        Text("Drop or click")
                            .font(.retraceMeta)
                            .foregroundColor(.retraceInk2)
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .fill(isDropTargeted ? Color.retraceAccentWash : Color.retraceSurfaceSunken)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                            .stroke(
                                isDropTargeted ? Color.retraceAccent : Color.retraceBorderStrong,
                                style: StrokeStyle(lineWidth: 1, dash: isDropTargeted ? [] : [4])
                            )
                    )
                }
                .buttonStyle(.plain)
                .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
                    handleImageDrop(providers)
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(
                    keyboardFocusTarget == .attachScreenshot
                        ? Color.retraceAccent
                        : Color.clear,
                    lineWidth: 2
                )
        )
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // Try to load as image directly
        if provider.canLoadObject(ofClass: NSImage.self) {
            provider.loadObject(ofClass: NSImage.self) { image, error in
                if let nsImage = image as? NSImage {
                    Task { @MainActor in
                        viewModel.attachImage(nsImage)
                    }
                }
            }
            return true
        }

        // Try to load as file URL
        if provider.hasItemConformingToTypeIdentifier("public.file-url") {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, error in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    Task { @MainActor in
                        viewModel.attachImage(from: url)
                    }
                }
            }
            return true
        }

        return false
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            RetraceSymbol("exclamationmark.triangle.fill", size: 14)
                .foregroundColor(.retraceCritical)
            Text(message)
                .font(.retraceCaption)
                .foregroundColor(.retraceCritical)
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceCriticalBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceCritical.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button(action: { dismiss() }) {
                Text("Cancel")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(Color.retraceSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .stroke(Color.retraceBorderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isSubmitting || viewModel.isExporting)

            Button(action: {
                keyboardFocusTarget = .submit
                Task { await viewModel.submit() }
            }) {
                Text("Send Feedback")
                    .font(.retraceCalloutBold)
                .foregroundColor(.retraceOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                        .fill(Color.retraceAccent)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.radiusMd + 2, style: .continuous)
                        .stroke(Color.retraceAccent, lineWidth: 2)
                        .padding(-4)
                        .opacity(keyboardFocusTarget == .submit ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .opacity(viewModel.canSubmit ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
        }
        .padding(.top, 4)
    }

    private var offlineExportCard: some View {
        HStack(alignment: .center, spacing: 12) {
            RetraceSymbol("arrow.down.doc", size: 14, weight: .semibold)
                .foregroundColor(.retraceAccent)
                .frame(width: 30, height: 30)
                .background(Color.retraceAccentWash)
                .clipShape(RoundedRectangle(cornerRadius: .radiusSm, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text("Need to send it manually?")
                    .font(.retraceCaptionBold)
                    .foregroundColor(.retraceInk)

                Text("Download the report as a .json.gz file and email it to support@retrace.to. If you attached an image, Retrace saves it next to the gzipped JSON file.")
                    .font(.retraceMeta)
                    .foregroundColor(.retraceMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Button(action: {
                keyboardFocusTarget = .downloadReport
                Task { await viewModel.exportFeedbackReport() }
            }) {
                HStack(spacing: 6) {
                    if viewModel.isExporting {
                        SpinnerView(size: 12, lineWidth: 2, color: .retraceInk2)
                    }
                    Text(viewModel.isExporting ? "Preparing..." : "Download .json.gz")
                        .font(.retraceCaptionBold)
                }
                .foregroundColor(.retraceInk)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .fill(Color.retraceSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: .radiusSm, style: .continuous)
                        .stroke(Color.retraceBorderStrong, lineWidth: 1)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CGFloat.radiusSm + 2, style: .continuous)
                        .stroke(Color.retraceAccent, lineWidth: 2)
                        .padding(-4)
                        .opacity(keyboardFocusTarget == .downloadReport ? 1 : 0)
                        .allowsHitTesting(false)
                )
                .opacity(viewModel.canExport ? 1 : 0.5)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canExport)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .fill(Color.retraceSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                .stroke(Color.retraceBorder, lineWidth: 1)
        )
        .retraceElevation(.sm)
    }

    // MARK: - Submitting View

    private var submittingView: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 18)

            submissionProgressOrb

            VStack(spacing: 8) {
                Text("Sending feedback")
                    .font(.retraceTitle2)
                    .foregroundColor(.retraceInk)
                    .multilineTextAlignment(.center)

                Group {
                    Text(viewModel.submissionDetail)
                        .id(viewModel.submissionStage)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
                .font(.retraceBody)
                .foregroundColor(.retraceInk2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity)
            .animation(.easeInOut(duration: 0.25), value: viewModel.submissionStage)

            Spacer()

            Text("Please keep this window open while we finish the upload.")
                .font(.retraceMeta)
                .foregroundColor(.retraceMuted)
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 56)
    }

    private var submissionFailureView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.retraceCriticalBg)
                    .frame(width: 84, height: 84)

                RetraceSymbol(viewModel.submissionFailureSymbolName, size: 28, weight: .semibold)
                    .foregroundColor(.retraceCritical)
            }

            VStack(spacing: 8) {
                Text(viewModel.submissionFailureTitle)
                    .font(.retraceTitle2)
                    .foregroundColor(.retraceInk)
                    .multilineTextAlignment(.center)

                Text(viewModel.submissionFailureDetail)
                    .font(.retraceBody)
                    .foregroundColor(.retraceInk2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }

            if viewModel.submissionFailureIsNetworkRelated {
                Button(action: { Task { await viewModel.exportFeedbackReport() } }) {
                    HStack(spacing: 8) {
                        if viewModel.isExporting {
                            SpinnerView(size: 14, lineWidth: 2, color: .retraceOnAccent)
                        }
                        Text(viewModel.isExporting ? "Preparing..." : "Download .json.gz")
                            .font(.retraceCalloutBold)
                    }
                    .foregroundColor(.retraceOnAccent)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(Color.retraceAccent)
                    )
                    .opacity(viewModel.canExport ? 1 : 0.5)
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canExport)
            }

            Button(action: { viewModel.clearSubmissionFailure() }) {
                Text("Back")
                    .font(.retraceCallout)
                    .foregroundColor(.retraceInk)
                    .frame(maxWidth: 220)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(Color.retraceSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .stroke(Color.retraceBorderStrong, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.vertical, 28)
        .padding(.horizontal, 56)
    }

    private var submissionProgressOrb: some View {
        ZStack {
            Circle()
                .stroke(Color.retraceBorder, lineWidth: 8)
                .frame(width: 88, height: 88)

            Circle()
                .trim(from: 0, to: max(0.06, viewModel.submissionProgress))
                .stroke(
                    Color.retraceAccent,
                    style: StrokeStyle(lineWidth: 8, lineCap: .round)
                )
                .frame(width: 88, height: 88)
                .rotationEffect(.degrees(-90))

            SpinnerView(size: 20, lineWidth: 2.2, color: .retraceInk2)
        }
        .frame(width: 100, height: 100)
        .padding(.bottom, 6)
    }

    // MARK: - Success View

    private var successView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.retraceGood, lineWidth: 2)
                    .frame(width: 112, height: 112)
                    .scaleEffect(successBurstScale)
                    .opacity(successBurstOpacity)

                Circle()
                    .fill(Color.retraceGoodBg)
                    .frame(width: 88, height: 88)
                    .scaleEffect(successIconScale)

                RetraceSymbol("checkmark", size: 36, weight: .semibold)
                    .foregroundColor(.retraceGood)
                    .scaleEffect(successIconScale)
                    .opacity(successIconOpacity)
            }
            .offset(y: successTextOffset * -0.35)

            VStack(spacing: 8) {
                Text(viewModel.completionPresentation?.title ?? "Feedback Sent!")
                    .font(.retraceTitle2)
                    .foregroundColor(.retraceInk)

                Text(viewModel.completionPresentation?.detail ?? "Thanks for helping improve Retrace.")
                    .font(.retraceBody)
                    .foregroundColor(.retraceInk2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }
            .opacity(successTextOpacity)
            .offset(y: successTextOffset)

            Spacer()

            if let completionPresentation = viewModel.completionPresentation {
                completionCallToAction(for: completionPresentation)
            }

            Spacer()

            // Close button
            Button(action: { dismiss() }) {
                Text("Done")
                    .font(.retraceCalloutBold)
                    .foregroundColor(.retraceOnAccent)
                    .frame(maxWidth: 200)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(Color.retraceAccent)
                    )
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
        .padding(28)
    }

    @ViewBuilder
    private func completionCallToAction(
        for presentation: FeedbackCompletionPresentation
    ) -> some View {
        if let linkTitle = presentation.linkTitle,
           let linkURL = presentation.linkURL {
            VStack(spacing: 14) {
                if let callToActionTitle = presentation.callToActionTitle {
                    Text(callToActionTitle)
                        .font(.retraceCaption)
                        .foregroundColor(.retraceInk2)
                }

                Link(destination: linkURL) {
                    HStack(spacing: 8) {
                        RetraceSymbol(presentation.linkSymbolName ?? "message.fill", size: 14)
                        Text(linkTitle)
                            .font(.retraceCallout)
                    }
                    .foregroundColor(.retraceInk)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .fill(Color.retraceSurface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: .radiusMd, style: .continuous)
                            .stroke(Color.retraceBorderStrong, lineWidth: 1)
                    )
                }
            }
        }
    }
}

private struct FeedbackWindowObserver: NSViewRepresentable {
    let onWindowNumberChange: (Int?) -> Void

    func makeNSView(context: Context) -> ObserverView {
        ObserverView(onWindowNumberChange: onWindowNumberChange)
    }

    func updateNSView(_ nsView: ObserverView, context: Context) {
        nsView.onWindowNumberChange = onWindowNumberChange
        nsView.reportWindowNumberIfNeeded()
    }

    final class ObserverView: NSView {
        var onWindowNumberChange: (Int?) -> Void
        private var lastReportedWindowNumber: Int?

        init(onWindowNumberChange: @escaping (Int?) -> Void) {
            self.onWindowNumberChange = onWindowNumberChange
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportWindowNumberIfNeeded()
        }

        func reportWindowNumberIfNeeded() {
            let windowNumber = window?.windowNumber
            guard windowNumber != lastReportedWindowNumber else { return }
            lastReportedWindowNumber = windowNumber

            DispatchQueue.main.async { [windowNumber, onWindowNumberChange] in
                onWindowNumberChange(windowNumber)
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
struct FeedbackFormView_Previews: PreviewProvider {
    static var previews: some View {
        FeedbackFormView()
    }
}
#endif
