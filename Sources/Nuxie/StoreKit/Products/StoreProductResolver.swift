import Foundation
import StoreKit

struct AppStorePlacementOptions: Equatable, Sendable {
    enum IntroEligibility: String, Codable, Equatable, Sendable {
        case automatic
        case alwaysEligible
        case alwaysIneligible
    }

    let introEligibility: IntroEligibility
    let billingPlan: StoreProduct.BillingPlan

    static let `default` = Self(
        introEligibility: .automatic,
        billingPlan: .default
    )
}

struct IntroEligibilityTokenRequest: Equatable, Hashable, Sendable {
    let experienceVersionId: String
    let placementId: String
    let authorization: IntroEligibilityAuthorizationContext
}

struct IntroEligibilityAuthorizationContext: Equatable, Hashable, Sendable {
    let distinctId: String
    let journeyId: String
    let legId: String
    let descriptorSha256: String
}

protocol IntroEligibilityAuthorizationContextProviding: AnyObject {
    var introEligibilityAuthorizationContext: IntroEligibilityAuthorizationContext { get }
}

func normalizedCompactJWS(_ value: String?) -> String? {
    guard let token = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !token.isEmpty else { return nil }
    let segments = token.split(separator: ".", omittingEmptySubsequences: false)
    guard segments.count == 3,
          segments.allSatisfy({ segment in
              !segment.isEmpty && segment.allSatisfy {
                  $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
              }
          }) else { return nil }
    return token
}

protocol IntroEligibilityTokenProviding: Sendable {
    func token(for request: IntroEligibilityTokenRequest) async throws -> String?
}

actor IntroEligibilityOverrideHealth {
    private var suppressed: Set<IntroEligibilityTokenRequest> = []

    func isSuppressed(_ request: IntroEligibilityTokenRequest) -> Bool {
        suppressed.contains(request)
    }

    func suppress(_ request: IntroEligibilityTokenRequest) {
        suppressed.insert(request)
    }
}

struct AppStoreIntroEligibilityTokenProvider: IntroEligibilityTokenProviding {
    let api: any IntroEligibilityTokenRequesting

    func token(for request: IntroEligibilityTokenRequest) async throws -> String? {
        #if compiler(>=6.1)
        guard #available(
            iOS 16.0,
            macOS 13.0,
            tvOS 16.0,
            watchOS 9.0,
            *
        ) else { return nil }
        let verification = try await AppTransaction.shared
        guard case .verified(let appTransaction) = verification,
              !appTransaction.appTransactionID.isEmpty else {
            return nil
        }
        return try await api.appStoreIntroEligibilityToken(
            distinctId: request.authorization.distinctId,
            journeyId: request.authorization.journeyId,
            experienceVersionId: request.experienceVersionId,
            legId: request.authorization.legId,
            descriptorSha256: request.authorization.descriptorSha256,
            placementId: request.placementId,
            transactionId: appTransaction.appTransactionID
        )
        #else
        return nil
        #endif
    }
}

struct UnavailableIntroEligibilityTokenProvider:
    IntroEligibilityTokenProviding
{
    func token(for request: IntroEligibilityTokenRequest) async throws -> String? { nil }
}

struct StoreProductResolver: Sendable {
    private let tokenProvider: any IntroEligibilityTokenProviding
    private let overrideHealth: IntroEligibilityOverrideHealth

    init(
        tokenProvider: any IntroEligibilityTokenProviding =
            UnavailableIntroEligibilityTokenProvider(),
        overrideHealth: IntroEligibilityOverrideHealth =
            IntroEligibilityOverrideHealth()
    ) {
        self.tokenProvider = tokenProvider
        self.overrideHealth = overrideHealth
    }

    func resolve(
        experienceVersionId: String,
        authorization: IntroEligibilityAuthorizationContext?,
        productId: String,
        placementId: String,
        productType: StoreProductType,
        appStoreProduct: any AppStoreProduct,
        options: AppStorePlacementOptions
    ) async throws -> StoreProduct {
        guard appStoreProduct.productType == productType else {
            throw StoreKitError.apiMisuse(
                reason: "The App Store product category does not match its signed Product"
            )
        }

        guard appStoreProduct.supportsBillingPlan(options.billingPlan) else {
            throw StoreKitError.noProductsAvailable
        }
        let appliedPlan = options.billingPlan
        let billingPeriod = appStoreProduct.billingPeriod(for: appliedPlan)
            ?? appStoreProduct.subscriptionPeriod
        let displayPrice = appStoreProduct.billingDisplayPrice(for: appliedPlan)
            ?? appStoreProduct.displayPrice
        let periodLabel = formatPeriod(
            billingPeriod,
            locale: appStoreProduct.priceLocale
        )

        let availableIntroductoryTerms = appStoreProduct.introductoryTerms(for: appliedPlan)
        if options.introEligibility != .automatic,
           authorization == nil {
            // Explicit eligibility is a Nuxie targeting decision, not a
            // client-selectable StoreKit mode. Reject it before inspecting
            // offer availability so a direct presentation cannot reveal a
            // product that would later require an unauthorized override.
            throw StoreKitError.noProductsAvailable
        }
        let configuredOverrideRequest: IntroEligibilityTokenRequest?
        if options.introEligibility != .automatic,
           availableIntroductoryTerms != nil,
           let authorization {
            configuredOverrideRequest = IntroEligibilityTokenRequest(
                experienceVersionId: experienceVersionId,
                placementId: placementId,
                authorization: authorization
            )
        } else {
            configuredOverrideRequest = nil
        }
        let eligibility: (eligible: Bool, overrideReady: Bool)
        if availableIntroductoryTerms == nil {
            eligibility = (false, false)
        } else {
            eligibility = try await resolveEligibility(
                product: appStoreProduct,
                mode: options.introEligibility,
                overrideRequest: configuredOverrideRequest
            )
        }
        let introductoryTerms = eligibility.eligible
            ? availableIntroductoryTerms
            : nil
        let hasRenewal = productType == .autoRenewable

        return StoreProduct(
            productId: productId,
            storeProductId: appStoreProduct.id,
            placementId: placementId,
            name: appStoreProduct.displayName,
            description: appStoreProduct.description,
            price: displayPrice,
            period: mapPeriod(billingPeriod),
            periodCount: billingPeriod?.value,
            periodLabel: periodLabel,
            renewalPrice: hasRenewal ? displayPrice : "",
            renewalPeriod: hasRenewal ? periodLabel : "",
            productType: productType,
            billingPlan: appliedPlan,
            commitmentPrice: appStoreProduct.commitmentDisplayPrice(for: appliedPlan) ?? "",
            commitmentPeriod: formatPeriod(
                appStoreProduct.commitmentPeriod(for: appliedPlan),
                locale: appStoreProduct.priceLocale
            ),
            introductoryTerms: introductoryTerms,
            introEligibilityTokenRequest: eligibility.overrideReady
                ? configuredOverrideRequest
                : nil,
            appStoreProduct: appStoreProduct
        )
    }

    private func resolveEligibility(
        product: any AppStoreProduct,
        mode: AppStorePlacementOptions.IntroEligibility,
        overrideRequest: IntroEligibilityTokenRequest?
    ) async throws -> (eligible: Bool, overrideReady: Bool) {
        switch mode {
        case .automatic:
            return (await product.isEligibleForIntroOffer(), false)
        case .alwaysEligible, .alwaysIneligible:
            guard let overrideRequest,
                  await !overrideHealth.isSuppressed(overrideRequest) else {
                throw StoreKitError.noProductsAvailable
            }
            let allow = mode == .alwaysEligible
            do {
                let token = normalizedCompactJWS(try await tokenProvider.token(
                    for: overrideRequest
                ))
                guard token != nil else {
                    throw StoreKitError.noProductsAvailable
                }
                return (allow, true)
            } catch {
                LogWarning(
                    "App Store introductory eligibility override unavailable"
                )
                throw StoreKitError.noProductsAvailable
            }
        }
    }

    private func mapPeriod(_ period: SubscriptionPeriod?) -> ProductPeriod? {
        guard let period else { return nil }
        switch period.unit {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        }
    }

    private func formatPeriod(_ period: SubscriptionPeriod?, locale: Locale) -> String {
        guard let period else { return "" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        let components: DateComponents
        switch period.unit {
        case .day:
            formatter.allowedUnits = [.day]
            components = DateComponents(day: period.value)
        case .week:
            formatter.allowedUnits = [.weekOfMonth]
            components = DateComponents(weekOfMonth: period.value)
        case .month:
            formatter.allowedUnits = [.month]
            components = DateComponents(month: period.value)
        case .year:
            formatter.allowedUnits = [.year]
            components = DateComponents(year: period.value)
        }
        return formatter.string(from: components) ?? ""
    }
}
