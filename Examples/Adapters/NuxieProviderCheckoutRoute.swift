import Nuxie

enum NuxieProviderCheckoutRoute: Equatable {
    case provider(introEligibilityJWS: String?)
    case storeKit
}

func revenueCatCheckoutRoute(
    introEligibilityJWS _: String?,
    billingPlan _: Nuxie.StoreProduct.BillingPlan
) -> NuxieProviderCheckoutRoute {
    .storeKit
}

func superwallCheckoutRoute() -> NuxieProviderCheckoutRoute {
    .storeKit
}
