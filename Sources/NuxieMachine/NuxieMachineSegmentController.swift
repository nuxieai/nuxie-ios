#if os(iOS) && !targetEnvironment(macCatalyst)
import UIKit

/// One segment of what an edge shows: one native presentation holding a run
/// of pages ([`NuxieMachineSheetState.cut(_:)`]). It is a navigation
/// controller with its bar hidden, presented as a sheet when its first
/// entry is a sheet and as a cover over the whole screen otherwise (a cover,
/// or a first entry shown as a push). Each page is one entry's Screen
/// ([`NuxieMachineScreenViewController`]); every page after the first was
/// pushed. There is no native Back button.
///
/// The segment carries what belongs to the presentation, and the page only
/// its Screen:
///
/// - its style, set once;
/// - a sheet's heights, as its first entry's row writes them
///   ([`detents`]), with a `fit-content` height read from the page on top;
/// - whether a swipe may take it away ([`modalReasons`]): held while a
///   swipe down on the sheet would press a control or do nothing, as the
///   machine answers it for the sheet's own entry ([`swipeDown`]), for a
///   cover, which has no swipe, and while a page of the segment waits for
///   its files.
///
/// The edge swipe goes back a page natively. The navigation controller's
/// own pop recognizer keeps working with the bar hidden, and asks the
/// segment before it begins ([`popMayBegin()`]), which reads what a swipe
/// back on the page on top does, as the machine answers it
/// ([`NuxieMachineScreenViewController.swipeBack`]):
///
/// - closes: the native pop runs, and once it completes (not when the
///   person lets go) the segment says so ([`onPopEnded`]);
/// - presses or stays: the pop does not begin, and the segment says the
///   swipe was held ([`onHeldSwipe`]), once.
///
/// A page at the bottom of the segment takes no edge swipe: UIKit offers
/// no pop there, and the machine answers that it stays.
@MainActor
package final class NuxieMachineSegmentController: UINavigationController {
    /// The segment's identity: the identity of its first page when it was
    /// presented ([`NuxieMachineSheetState.Segment.id`]).
    package let id: NuxieMachineShown

    /// The entry that starts the segment, as the session last showed it:
    /// the sheet or the cover, or the first page shown as a push.
    package private(set) var bottom: NuxieMachinePresented

    /// Whether the segment is presented as a sheet.
    package let isSheet: Bool

    /// What a swipe down on this sheet does now, as the machine last
    /// answered it for the sheet's own entry, which reads the page on top:
    /// `nil` for a cover. The presenter sets it from every report
    /// ([`follow`]), so it is never older than the frame on screen, and
    /// UIKit reads it at once when the person starts to drag: while it says
    /// the sheet stays or a control is pressed, the native dismissal is
    /// held ([`modalReasons`]).
    package private(set) var swipeDown: NuxieMachineSwipeWould? {
        didSet { holdSwipe() }
    }

    /// Why this segment does not let the person swipe it away now.
    /// `isModalInPresentation` is true exactly while the set is not empty,
    /// and nothing else writes it. The edge swipe on a pushed page does not
    /// read it: that reads the page's own answer.
    package var modalReasons: Set<NuxieMachineModalReason> = [] {
        didSet { isModalInPresentation = !modalReasons.isEmpty }
    }

    /// The heights this sheet may rest at, as its first entry's row writes
    /// them. None for a cover.
    package private(set) var detents: [NuxieMachineDetent]

    /// The height of the content of the page on top, in points, at the
    /// sheet's width, as the engine last measured it: what a `fit-content`
    /// detent rests at. None until it is measured, or when the engine
    /// cannot measure it; the detent then rests at the largest height.
    package private(set) var contentHeight: CGFloat?

    /// Told when UIKit held a swipe, or the screen reader's escape asked for
    /// one, with the gesture and what it is for: back, the page on top; or
    /// down, the segment ([`id`]). The presenter delivers it as a swipe.
    package var onHeldSwipe: (@MainActor (NuxieMachineSwipeGesture, NuxieMachineShown) -> Void)?
    /// Told when the person begins swiping the page on top back from the
    /// edge, with that page.
    package var onPopBegan: (@MainActor (NuxieMachineShown) -> Void)?
    /// Told when the person's swipe back of that page ends: whether UIKit
    /// popped it, or the swipe was let go and the page is back.
    package var onPopEnded: (@MainActor (NuxieMachineShown, Bool) -> Void)?

    /// How UIKit animated the last change of pages, as it said when it
    /// asked for the animation: a push when the new top page is new, a pop
    /// when it is a kept one. For checks.
    package private(set) var lastOperation: UINavigationController.Operation = .none

    /// The most the sheet can be, in points, that its detents are ordered
    /// for: the presenter's estimate ([`orderDetents`]) until UIKit has
    /// resolved a detent of this module's, then what UIKit resolved it
    /// against ([`resolved`]). None until one of them says.
    private var orderMaximum: CGFloat?
    /// The `maximumDetentValue` UIKit last resolved a detent of this
    /// module's against. Once there is one, estimates are not taken.
    private var resolvedMaximum: CGFloat?
    /// The detents last handed to UIKit, in that order.
    private var appliedDetents: [NuxieMachineDetent]?
    /// The navigation delegate and the pop recognizer's delegate: an object
    /// of its own, so nothing UIKit's navigation controller does for itself
    /// is overridden.
    private lazy var watcher = NuxieMachineSegmentWatcher(self)

    /// A segment holding `pages`, bottom first. How it is presented is set
    /// here, once, from its first page:
    ///
    /// - A sheet: a page sheet with no grabber, at the heights its row
    ///   writes ([`nativeDetents`]), or at the large detent when it writes
    ///   none. Whether a swipe may take it is the machine's answer
    ///   ([`swipeDown`]): a swipe that would close it runs natively; one
    ///   that would press a control, or do nothing, is held, and the
    ///   presenter delivers it. Over a `scroll`, a drag stays with the page
    ///   unless it is downward with the page at its top
    ///   ([`NuxieMachineSheetPan`]).
    /// - Anything else: full screen, which has no swipe down.
    ///
    /// Either way each page fills the segment to every edge, under the
    /// status bar and the home indicator where they reach it, and is told
    /// the segment's insets so its page keeps its content clear of them
    /// ([`NuxieMachineScreenViewController.place`]): a pushed page inside a
    /// sheet gets the sheet's.
    package init(id: NuxieMachineShown? = nil, pages: [NuxieMachineScreenViewController]) {
        precondition(!pages.isEmpty, "a segment holds a page")
        let bottom = pages[0].presented
        self.id = id ?? bottom.shown
        self.bottom = bottom
        isSheet = bottom.presentation == .sheet
        detents = isSheet ? bottom.detents : []
        swipeDown = isSheet ? bottom.swipeDown : nil
        super.init(nibName: nil, bundle: nil)
        setViewControllers(pages, animated: false)
        setNavigationBarHidden(true, animated: false)
        delegate = watcher
        modalPresentationStyle = isSheet ? .pageSheet : .fullScreen
        holdSwipe()
        pageLoadingChanged()
        if isSheet, let sheet = sheetPresentationController {
            applyDetents()
            sheet.prefersGrabberVisible = false
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override package func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // With the bar hidden, the pop recognizer works only while it has a
        // delegate that lets it.
        interactivePopGestureRecognizer?.delegate = watcher
    }

    /// The pages, bottom first.
    package var pages: [NuxieMachineScreenViewController] {
        viewControllers.compactMap { $0 as? NuxieMachineScreenViewController }
    }

    /// Take what the session shows of the segment's first entry now: what
    /// a swipe down does, and the heights it rests at. The presenter calls
    /// it with every report; a report of another entry changes nothing.
    package func follow(_ now: NuxieMachinePresented) {
        guard now.shown == bottom.shown else { return }
        bottom = now
        guard isSheet else { return }
        if swipeDown != now.swipeDown { swipeDown = now.swipeDown }
        guard detents != now.detents else { return }
        detents = now.detents
        applyDetents()
    }

    /// Set the pages to `pages`, bottom first, in one change of UIKit's,
    /// animated while the segment is on screen: a push when the new top
    /// page is new, a pop when it is a kept one. `completion` is told when
    /// the change is over, at once when nothing animates.
    package func setPages(_ pages: [NuxieMachineScreenViewController],
                          completion: @escaping @MainActor () -> Void) {
        guard let first = pages.first else { return completion() }
        bottom = first.presented
        let animated = viewIfLoaded?.window != nil
        setViewControllers(pages, animated: animated)
        pageLoadingChanged()
        guard animated, let coordinator = transitionCoordinator else { return completion() }
        coordinator.animate(alongsideTransition: nil) { _ in
            MainActor.assumeIsolated { completion() }
        }
    }

    // MARK: The edge swipe

    /// Whether the pop recognizer may begin, asked when the person starts a
    /// swipe from the edge: only on a pushed page on top, with a page of the
    /// segment beneath it, and no transition under way. Its answer is the
    /// machine's: a swipe that closes the page begins; one that presses a
    /// control or does nothing does not, and is delivered once as held.
    package func popMayBegin() -> Bool {
        guard viewControllers.count > 1, transitionCoordinator == nil,
              let top = topViewController as? NuxieMachineScreenViewController, top !== viewControllers.first,
              let back = top.swipeBack else { return false }
        switch back {
        case .closes:
            return true
        case .stays, .presses:
            onHeldSwipe?(.back, top.shown)
            return false
        }
    }

    /// UIKit is about to show `shown` with an interactive transition: the
    /// person's swipe back of the page `leaving`. It is followed through the
    /// transition's coordinator to its end: popped, or let go.
    fileprivate func followPop(of leaving: NuxieMachineScreenViewController,
                               _ coordinator: any UIViewControllerTransitionCoordinator) {
        let page = leaving.shown
        onPopBegan?(page)
        coordinator.animate(alongsideTransition: nil) { [weak self] context in
            let completed = !context.isCancelled
            MainActor.assumeIsolated { self?.onPopEnded?(page, completed) }
        }
    }

    fileprivate func willAnimate(_ operation: UINavigationController.Operation) {
        lastOperation = operation
    }

    /// The pages changed and the change is over: a `fit-content` sheet is
    /// worked out again for the page now on top, which measures its content
    /// at its next frame.
    fileprivate func pagesShown() {
        guard fitsContent, #available(iOS 16.0, *), let sheet = sheetPresentationController,
              sheet.containerView != nil else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    // MARK: The screen reader's escape

    /// The screen reader's escape (the two-finger Z) on `page`, a page of
    /// this segment, as the gesture it stands for:
    ///
    /// - on a pushed page with a page of the segment beneath it, a swipe
    ///   back, read from the page's own answer;
    /// - otherwise, on a sheet, a swipe down, read from the sheet's answer;
    ///   passed on while a page of the sheet waits for its files, since the
    ///   close is the way out then;
    /// - on a cover's first page, nothing.
    ///
    /// Where the swipe would do nothing, the escape is passed on and
    /// nothing is delivered. Otherwise the presenter delivers it once, and
    /// there is no native gesture to wait for: the machine acts, and the
    /// next report moves the native pages.
    package func escape(from page: NuxieMachineScreenViewController) -> Bool {
        if let at = viewControllers.firstIndex(of: page), at > 0 {
            guard let back = page.swipeBack, back != .stays, let onHeldSwipe else { return false }
            onHeldSwipe(.back, page.shown)
            return true
        }
        guard isSheet, !modalReasons.contains(.loading), swipeDown == .presses || swipeDown == .closes,
              let onHeldSwipe else { return false }
        onHeldSwipe(.down, id)
        return true
    }

    // MARK: Why a swipe may not take it

    /// Whether the native dismissal is held: for a cover, which has no
    /// swipe, and for a sheet whose swipe down would press a control or do
    /// nothing. A sheet whose swipe closes it lets UIKit run it.
    private func holdSwipe() {
        let refused = !isSheet || swipeDown == .stays || swipeDown == .presses
        if refused { modalReasons.insert(.swipeRefused) } else { modalReasons.remove(.swipeRefused) }
    }

    /// Whether a page of the segment waits for its files, which holds the
    /// native dismissal: its close is the way out, so no swipe down is
    /// delivered then. Read again whenever a page's wait changes or the
    /// pages change.
    package func pageLoadingChanged() {
        if pages.contains(where: \.waitsForFiles) {
            modalReasons.insert(.loading)
        } else {
            modalReasons.remove(.loading)
        }
    }

    // MARK: A sheet's heights

    /// Order the sheet's detents for UIKit for a sheet estimated to be at
    /// most `maximum` points tall: the presenter calls it before it
    /// presents the sheet, so its first presentation has an order. Once
    /// UIKit has resolved a detent ([`resolved`]) the estimate is not taken.
    package func orderDetents(estimatedMaximum maximum: CGFloat) {
        guard resolvedMaximum == nil, maximum.isFinite, maximum > 0, maximum != orderMaximum else { return }
        orderMaximum = maximum
        applyDetents()
    }

    /// The presenter's estimate of the most a sheet presented in `window`
    /// can be: its height inside its top and bottom insets, as UIKit leaves
    /// an edge-attached sheet.
    package static func estimatedSheetMaximum(in window: UIView) -> CGFloat {
        window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom
    }

    /// UIKit resolved one of this module's detents against `maximum`, its
    /// `maximumDetentValue`: the order follows it from then on, and the
    /// detents are worked out again when it changes it (a turn of the
    /// phone, a change of size class, a window resized on iPad). A sheet
    /// with only the system's medium and large has nothing to resolve, and
    /// medium is always the shorter.
    package func resolved(maximum: CGFloat) {
        guard maximum.isFinite, maximum > 0, maximum != resolvedMaximum else { return }
        resolvedMaximum = maximum
        guard maximum != orderMaximum else { return }
        orderMaximum = maximum
        applyDetents()
        guard #available(iOS 16.0, *), let sheet = sheetPresentationController, sheet.containerView != nil
        else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    /// Hand UIKit the sheet's detents in the order they now take, when it
    /// changed. Each keeps its identifier, so a sheet resting at one still
    /// rests at it after the order changes.
    private func applyDetents() {
        guard isSheet, let sheet = sheetPresentationController else { return }
        let order = nativeDetents()
        guard order != appliedDetents else { return }
        appliedDetents = order
        let made = order.isEmpty ? [UISheetPresentationController.Detent.large()] : order.map(sheetDetent)
        let names: [UISheetPresentationController.Detent.Identifier] =
            order.isEmpty ? [.large] : order.map(Self.identifier(of:))
        let selected = sheet.selectedDetentIdentifier
        let change = {
            sheet.detents = made
            if let selected, names.contains(selected) { sheet.selectedDetentIdentifier = selected }
        }
        // Before the sheet is presented there is nothing to animate.
        if sheet.containerView == nil { change() } else { sheet.animateChanges(change) }
    }

    /// The heights the sheet rests at, as UIKit takes them: each once, from
    /// the shortest to the tallest at the most the sheet can be now
    /// ([`nativeOrder`]); in the order its row writes them until that is
    /// known. Before iOS 16 a sheet has the system's two alone, and every
    /// height but medium rests at large. A row that writes none rests at
    /// large. What the machine shows ([`detents`]) keeps the row's order.
    private func nativeDetents() -> [NuxieMachineDetent] {
        var kinds = detents
        if #unavailable(iOS 16.0) { kinds = kinds.map { $0 == .medium ? .medium : .large } }
        return Self.nativeOrder(of: kinds, maximum: orderMaximum, contentHeight: contentHeight)
    }

    /// `detents` each once, the first of equal ones kept, and with a
    /// `maximum`, sorted by the height each rests at when the most a sheet
    /// can be is `maximum`: large at all of it, this module's own by
    /// [`height`], as UIKit resolves them, and medium at half of it. Equal
    /// heights keep the row's order.
    ///
    /// Medium is an approximation: UIKit resolves the system's medium
    /// itself, and no public API gives its height, so a detent of this
    /// module's within a few points of half the maximum may be ordered on
    /// the wrong side of it.
    package nonisolated static func nativeOrder(of detents: [NuxieMachineDetent], maximum: CGFloat?,
                                                contentHeight: CGFloat?) -> [NuxieMachineDetent] {
        var once: [NuxieMachineDetent] = []
        for detent in detents where !once.contains(detent) { once.append(detent) }
        guard let maximum else { return once }
        func resting(_ detent: NuxieMachineDetent) -> CGFloat {
            switch detent {
            case .medium: maximum / 2
            case .large: maximum
            default: height(of: detent, maximum: maximum, contentHeight: contentHeight) ?? maximum
            }
        }
        return once.enumerated()
            .sorted { one, other in
                let (low, high) = (resting(one.element), resting(other.element))
                return low != high ? low < high : one.offset < other.offset
            }
            .map(\.element)
    }

    private func sheetDetent(_ detent: NuxieMachineDetent) -> UISheetPresentationController.Detent {
        switch detent {
        case .medium: return .medium()
        case .large: return .large()
        case .points, .percent, .fitContent:
            guard #available(iOS 16.0, *) else { return .large() }
            // UIKit works a detent out on the main thread.
            return .custom(identifier: Self.identifier(of: detent)) { [weak self] context in
                MainActor.assumeIsolated {
                    let maximum = context.maximumDetentValue
                    // The order follows what UIKit resolves against, but not
                    // while it is resolving: after it, on the main actor.
                    if let self, maximum != self.resolvedMaximum {
                        Task { @MainActor [weak self] in self?.resolved(maximum: maximum) }
                    }
                    return Self.height(of: detent, maximum: maximum, contentHeight: self?.contentHeight)
                }
            }
        }
    }

    /// The identifier of one of this module's detents: its kind and its
    /// number, the same each time it is read.
    package static func identifier(of detent: NuxieMachineDetent) -> UISheetPresentationController.Detent.Identifier {
        switch detent {
        case .medium: .medium
        case .large: .large
        case .points(let points): .init(rawValue: "nuxie.points.\(points)")
        case .percent(let percent): .init(rawValue: "nuxie.percent.\(percent)")
        case .fitContent: .init(rawValue: "nuxie.fit-content")
        }
    }

    /// The height one of this module's detents rests at, in points, when
    /// the most a sheet can be is `maximum`: a height in points, never more
    /// than that; a percent of it; or the content's measured height, never
    /// more than that, and that whole height until it is measured. None
    /// for the system's medium and large, which UIKit works out.
    package nonisolated static func height(of detent: NuxieMachineDetent, maximum: CGFloat, contentHeight: CGFloat?) -> CGFloat? {
        switch detent {
        case .medium, .large:
            return nil
        case .points(let points):
            return min(CGFloat(points), maximum)
        case .percent(let percent):
            return maximum * CGFloat(percent) / 100
        case .fitContent:
            guard let contentHeight, contentHeight.isFinite, contentHeight > 0 else { return maximum }
            return min(contentHeight, maximum)
        }
    }

    /// The content's height of the page on top as the engine measured it
    /// after a frame, for a sheet that rests at it: when it changes, UIKit
    /// works the sheet's detents out again. A height the engine cannot give
    /// leaves the detent where it is.
    package func measured(contentHeight height: CGFloat?) {
        guard let height, height.isFinite, height > 0, height != contentHeight else { return }
        contentHeight = height
        // The content's height can move fit-content past another detent.
        applyDetents()
        guard #available(iOS 16.0, *), isSheet, let sheet = sheetPresentationController else { return }
        sheet.animateChanges { sheet.invalidateDetents() }
    }

    /// Whether this sheet rests at its content's height, so each frame the
    /// page on top draws measures that height.
    package var fitsContent: Bool { isSheet && detents.contains(.fitContent) }
}

/// The segment's navigation delegate and its pop recognizer's delegate.
@MainActor
private final class NuxieMachineSegmentWatcher: NSObject, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    private weak var segment: NuxieMachineSegmentController?

    init(_ segment: NuxieMachineSegmentController) {
        self.segment = segment
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let segment, gestureRecognizer === segment.interactivePopGestureRecognizer else { return true }
        return segment.popMayBegin()
    }

    func navigationController(_ navigationController: UINavigationController, willShow viewController: UIViewController,
                              animated: Bool) {
        guard let segment, navigationController === segment,
              let coordinator = navigationController.transitionCoordinator, coordinator.isInteractive,
              let leaving = coordinator.viewController(forKey: .from) as? NuxieMachineScreenViewController,
              leaving !== viewController else { return }
        segment.followPop(of: leaving, coordinator)
    }

    func navigationController(_ navigationController: UINavigationController, didShow viewController: UIViewController,
                              animated: Bool) {
        segment?.pagesShown()
    }

    /// UIKit asks how to animate a change of pages, naming the operation.
    /// Nothing custom: the platform's own push and pop, its edge swipe
    /// among them.
    func navigationController(_ navigationController: UINavigationController,
                              animationControllerFor operation: UINavigationController.Operation,
                              from fromVC: UIViewController,
                              to toVC: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? {
        segment?.willAnimate(operation)
        return nil
    }
}
#endif
