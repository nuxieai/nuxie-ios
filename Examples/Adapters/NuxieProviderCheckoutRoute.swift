import Nuxie

enum NuxieProviderCheckoutRoute: Equatable {
    case provider(introEligibilityJWS: String?)
    case storeKit
}

func revenueCatCheckoutRoute(
    introEligibilityJWS: String?,
    billingPlan: Nuxie.StoreProduct.BillingPlan
) -> NuxieProviderCheckoutRoute {
    billingPlan == .monthly || billingPlan == .upFront
        ? .storeKit
        : .provider(introEligibilityJWS: introEligibilityJWS)
}

func superwallCheckoutRoute() -> NuxieProviderCheckoutRoute {
    .storeKit
}
