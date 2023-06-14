#import "PlaidFlutterPlugin.h"
#import <LinkKit/LinkKit.h>

static NSString* const kPublicKeyKey = @"publicKey";
static NSString* const kTokenKey = @"token";
static NSString* const kClientNameKey = @"clientName";
static NSString* const kEnvironmentKey = @"environment";
static NSString* const kProductsKey = @"products";
static NSString* const kWebhookKey = @"webhook";
static NSString* const kInstitutionKey = @"institution";
static NSString* const kLinkCustomizationName = @"linkCustomizationName";
static NSString* const kAccountSubtypes = @"accountSubtypes";
static NSString* const kCountryCodesKey = @"countryCodes";
static NSString* const kLanguageKey = @"language";
static NSString* const kUserLegalNameKey = @"userLegalName";
static NSString* const kUserEmailAddressKey = @"userEmailAddress";
static NSString* const kUserPhoneNumberKey = @"userPhoneNumber";
static NSString* const kNoLoadingStateKey = @"noLoadingState";
static NSString* const kOAuthRedirectUriKey = @"oauthRedirectUri";
static NSString* const kOAuthNonceKey = @"oauthNonce";
static NSString* const kContinueRedirectUriKey = @"redirectUri";

static NSString* const kLinkTokenPrefix = @"link-";
static NSString* const kItemAddTokenPrefix = @"item-add-";
static NSString* const kPaymentTokenPrefix = @"payment";
static NSString* const kDepositSwitchTokenPrefix = @"deposit-switch-";
static NSString* const kPublicTokenPrefix = @"public-";

static NSString* const kOnSuccessType = @"success";
static NSString* const kOnExitType = @"exit";
static NSString* const kOnEventType = @"event";
static NSString* const kErrorKey = @"error";
static NSString* const kMetadataKey = @"metadata";
static NSString* const kPublicTokenKey = @"publicToken";
static NSString* const kNameKey = @"name";
static NSString* const kTypeKey = @"type";

//static NSString* const kSelectAccountKey = @"selectAccount";
//static NSString* const kLongtailAuthKey = @"longtailAuth";
//static NSString* const kOAuthStateIdKey = @"oauthStateId";

@interface PlaidFlutterPlugin () <FlutterStreamHandler>
@end

@implementation PlaidFlutterPlugin {
    FlutterEventSink _eventSink;
    id<PLKHandler> _linkHandler;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *methodChannel = [FlutterMethodChannel methodChannelWithName:@"plugins.flutter.io/plaid_flutter"
                                                                binaryMessenger:[registrar messenger]];
    
    FlutterEventChannel *eventChannel = [FlutterEventChannel eventChannelWithName:@"plugins.flutter.io/plaid_flutter/events"
                                                                  binaryMessenger:[registrar messenger]];
    
    PlaidFlutterPlugin *instance = [[PlaidFlutterPlugin alloc] init];
    [registrar addMethodCallDelegate:instance channel:methodChannel];
    [eventChannel setStreamHandler:instance];
}

- (void)dealloc {
  _linkHandler = nil;
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if ([@"open" isEqualToString:call.method])
        [self openWithArguments: call.arguments];
    else if ([@"close" isEqualToString:call.method])
        [self close];
    else if([@"continueFromRedirectUri" isEqualToString:call.method])
        [self continueFromRedirectUriString:call.arguments];
    else
        result(FlutterMethodNotImplemented);
    
}

#pragma mark FlutterStreamHandler implementation

- (void) sendEventWithArguments:(id _Nullable)arguments {
    if (!_eventSink)
        return;
    
    _eventSink(arguments);
}

- (FlutterError *)onListenWithArguments:(id)arguments
                              eventSink:(FlutterEventSink)eventSink {
    _eventSink = eventSink;
    return nil;
}

- (FlutterError *)onCancelWithArguments:(id)arguments {
    _eventSink = nil;
    return nil;
}

#pragma mark Exposed methods

- (void) openWithArguments: (id _Nullable)arguments  {
    
    NSString* institution = arguments[kInstitutionKey];
    NSString* token = arguments[kTokenKey];
    BOOL noLoadingState = arguments[kNoLoadingStateKey];
    
    __weak typeof(self) weakSelf = self;
    
    PLKOnSuccessHandler successHandler = ^(PLKLinkSuccess *success) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf close];
        [strongSelf sendEventWithArguments: @{kTypeKey: kOnSuccessType,
                                              kPublicTokenKey: success.publicToken ?: @"",
                                              kMetadataKey : [PlaidFlutterPlugin dictionaryFromSuccessMetadata:success.metadata]}];
    };
    
    PLKOnExitHandler exitHandler = ^(PLKLinkExit *exit) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf close];
        
        NSMutableDictionary* arguments = [[NSMutableDictionary alloc] init];
        [arguments setObject:kOnExitType forKey:kTypeKey];
        [arguments setObject:[PlaidFlutterPlugin dictionaryFromExitMetadata: exit.metadata] forKey:kMetadataKey];
        
        if(exit.error) {
            [arguments setObject:[PlaidFlutterPlugin dictionaryFromError:exit.error] ?: @{} forKey:kErrorKey];
        }
        
        [strongSelf sendEventWithArguments: arguments];
    };
    
    PLKOnEventHandler eventHandler = ^(PLKLinkEvent *event) {
        __strong typeof(self) strongSelf = weakSelf;
        [strongSelf sendEventWithArguments:@{kTypeKey: kOnEventType,
                                             kNameKey: [PlaidFlutterPlugin stringForEventName: event.eventName] ?: @"",
                                             kMetadataKey: [PlaidFlutterPlugin dictionaryFromEventMetadata: event.eventMetadata]}];
    };
    
    BOOL usingLinkToken = [token isKindOfClass:[NSString class]] && [token hasPrefix:kLinkTokenPrefix];
    NSError *creationError = nil;
    
    if (usingLinkToken) {
        PLKLinkTokenConfiguration *config = [self getLinkTokenConfigurationWithToken:token onSuccessHandler:successHandler];
        config.onEvent = eventHandler;
        config.onExit = exitHandler;
        config.noLoadingState = noLoadingState;

        _linkHandler = [PLKPlaid createWithLinkTokenConfiguration:config error:&creationError];
    } else {
        PLKLinkPublicKeyConfiguration *config = [self getLegacyLinkConfigurationWithArguments:arguments onSuccessHandler:successHandler];
        config.onEvent = eventHandler;
        config.onExit = exitHandler;
        
        _linkHandler = [PLKPlaid createWithLinkPublicKeyConfiguration:config error:&creationError];
    }

    if (_linkHandler) {
        NSDictionary *options = [institution isKindOfClass:[NSString class]] ? @{@"institution_id": institution} : @{};
        __block bool didPresent = NO;
        
        void(^presentationHandler)(UIViewController *) = ^(UIViewController *linkViewController) {
            UIViewController* rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
            [rootViewController presentViewController:linkViewController animated:YES completion:nil];
            didPresent = YES;
        };
        
        void(^dismissalHandler)(UIViewController *) = ^(UIViewController *linkViewController) {
            if (didPresent) {
                [weakSelf close];
                didPresent = NO;
            }
        };

        [_linkHandler openWithPresentationHandler:presentationHandler dismissalHandler:dismissalHandler options:options];

    } else if(creationError) {
        NSLog(@"Unable to create PLKHandler due to: %@", [creationError localizedDescription]);
        [self sendEventWithArguments: [FlutterError errorWithCode: [NSString stringWithFormat:@"%lld", (long long)creationError.code] ?: @""
                                                          message: [creationError localizedDescription] ?: @""
                                                          details: @"Unable to create PLKHandler"]];
    } else {
        NSLog(@"Unexpected Creation Error");
    }
}

- (void) close {
    UIViewController* rootViewController = [UIApplication sharedApplication].delegate.window.rootViewController;
    [rootViewController dismissViewControllerAnimated:YES completion:nil];
    _linkHandler = nil;
}

- (void) continueFromRedirectUriString: (id _Nullable)arguments {
    NSString* redirectUriString = arguments[kContinueRedirectUriKey];
    NSURL *redirectUriURL = (id)redirectUriString == [NSNull null] ? nil : [NSURL URLWithString:redirectUriString];

    if (redirectUriURL && _linkHandler) {
       [_linkHandler continueWithRedirectUri:redirectUriURL];
    }
}

#pragma mark PLKConfiguration

- (PLKLinkTokenConfiguration*)getLinkTokenConfigurationWithToken: (NSString *)token onSuccessHandler:(PLKOnSuccessHandler)successHandler{
    return [PLKLinkTokenConfiguration createWithToken:token onSuccess:successHandler];
}

- (PLKLinkPublicKeyConfiguration*)getLegacyLinkConfigurationWithArguments:(id _Nullable)arguments onSuccessHandler:(PLKOnSuccessHandler)successHandler{
    NSString* token = arguments[kTokenKey];
    NSString* environment = arguments[kEnvironmentKey];
    NSString* publicKey = arguments[kPublicKeyKey];
    NSArray<NSString*>* products = arguments[kProductsKey];
    NSString* clientName = arguments[kClientNameKey];
    NSString* webhook = arguments[kWebhookKey];
    NSString* language = arguments[kLanguageKey];
    NSString* userLegalName = arguments[kUserLegalNameKey];
    NSString* userEmailAddress = arguments[kUserEmailAddressKey];
    NSString* userPhoneNumber = arguments[kUserPhoneNumberKey];
    NSString* linkCustomizationName = arguments[kLinkCustomizationName];
    NSArray<NSString*>* countryCodes = arguments[kCountryCodesKey];
    NSArray<NSDictionary<NSString*,NSString*>*>* accountSubtypes = arguments[kAccountSubtypes];
    NSString* oauthRedirectUri = arguments[kOAuthRedirectUriKey];
    NSString* oauthNonce = arguments[kOAuthNonceKey];
    
    PLKLinkPublicKeyConfigurationToken *configurationToken;
    BOOL isPaymentToken = [token isKindOfClass:[NSString class]] && [token hasPrefix:kPaymentTokenPrefix];
    BOOL isItemAddToken = [token isKindOfClass:[NSString class]] && [token hasPrefix:kItemAddTokenPrefix];
    BOOL isDepositSwitchToken = [token isKindOfClass:[NSString class]] && [token hasPrefix:kDepositSwitchTokenPrefix];
    BOOL isPublicToken = [token isKindOfClass:[NSString class]] && [token hasPrefix:kPublicTokenPrefix];
    
    if (isPaymentToken) {
        configurationToken = [PLKLinkPublicKeyConfigurationToken createWithPaymentToken:token publicKey:publicKey];
    } else if (isItemAddToken) {
        configurationToken = [PLKLinkPublicKeyConfigurationToken createWithPublicToken:token publicKey:publicKey];
    } else if (isDepositSwitchToken) {
        configurationToken = [PLKLinkPublicKeyConfigurationToken createWithDepositSwitchToken:token publicKey:publicKey];
    } else if (isPublicToken) {
        configurationToken = [PLKLinkPublicKeyConfigurationToken createWithPublicToken:token publicKey:publicKey];
    } else {
        configurationToken = [PLKLinkPublicKeyConfigurationToken createWithPublicKey:publicKey];
    }
        
    PLKEnvironment env = [PlaidFlutterPlugin environmentFromString:environment];
    NSArray<NSNumber *> *productsIds = [PlaidFlutterPlugin productsArrayFromProductsStringArray:products];
    
    PLKLinkPublicKeyConfiguration *linkConfiguration = [[PLKLinkPublicKeyConfiguration alloc] initWithClientName:clientName
                                                                                                     environment:env
                                                                                                        products:productsIds
                                                                                                        language:language
                                                                                                           token:configurationToken
                                                                                                    countryCodes:countryCodes
                                                                                                       onSuccess:successHandler];

    if([linkCustomizationName isKindOfClass:[NSString class]]) {
        linkConfiguration.linkCustomizationName = linkCustomizationName;
    }
    
    if([webhook isKindOfClass:[NSString class]]) {
        linkConfiguration.webhook = [NSURL URLWithString:webhook];
    }
    
    if([userLegalName isKindOfClass:[NSString class]]) {
        linkConfiguration.userLegalName = userLegalName;
    }
    
    if([userEmailAddress isKindOfClass:[NSString class]]) {
        linkConfiguration.userEmailAddress = userEmailAddress;
    }
    
    if ([userPhoneNumber isKindOfClass:[NSString class]]) {
        linkConfiguration.userPhoneNumber = userPhoneNumber;
    }
    
    if ([oauthRedirectUri isKindOfClass:[NSString class]] && [oauthNonce isKindOfClass:[NSString class]]) {
        linkConfiguration.oauthConfiguration = [PLKOAuthNonceConfiguration createWithNonce:oauthNonce redirectUri:[NSURL URLWithString:oauthRedirectUri]];
    }
    
    if([accountSubtypes isKindOfClass:[NSDictionary class]]) {
        linkConfiguration.accountSubtypes = [PlaidFlutterPlugin accountSubtypesArrayFromAccountSubtypeDictionaries:accountSubtypes];
    }

    return linkConfiguration;
}

#pragma mark PLKConfiguration Parsing

+ (PLKEnvironment)environmentFromString:(NSString *)string {
    if ([string isEqualToString:@"production"]) {
        return PLKEnvironmentProduction;
    }

    if ([string isEqualToString:@"sandbox"]) {
        return PLKEnvironmentSandbox;
    }

    if ([string isEqualToString:@"development"]) {
        return PLKEnvironmentDevelopment;
    }

    return PLKEnvironmentDevelopment;
}

+ (NSArray<NSNumber *> *)productsArrayFromProductsStringArray:(NSArray<NSString *> *)productsStringArray {
    NSMutableArray<NSNumber *> *results = [NSMutableArray arrayWithCapacity:productsStringArray.count];

    for (NSString *productString in productsStringArray) {
        NSNumber *product = [PlaidFlutterPlugin productFromProductString:productString];
        if (product) {
            [results addObject:product];
        }
    }

    return [results copy];
}

+ (NSNumber * __nullable)productFromProductString:(NSString *)productString {
    NSDictionary *productStringMap = @{
        @"auth": @(PLKProductAuth),
        @"identity": @(PLKProductIdentity),
        @"income": @(PLKProductIncome),
        @"transactions": @(PLKProductTransactions),
        @"assets": @(PLKProductAssets),
        @"liabilities": @(PLKProductLiabilities),
        @"investments": @(PLKProductInvestments),
        @"deposit_switch": @(PLKProductDepositSwitch),
        @"payment_initiation": @(PLKProductPaymentInitiation),
    };
    return productStringMap[productString.lowercaseString];
}

+ (NSArray<id<PLKAccountSubtype>> *)accountSubtypesArrayFromAccountSubtypeDictionaries:(NSArray<NSDictionary<NSString *, NSString *> *> *)accountSubtypeDictionaries {
    __block NSMutableArray<id<PLKAccountSubtype>> *results = [NSMutableArray array];
    
    for (NSDictionary *accountSubtypeDictionary in accountSubtypeDictionaries) {
        NSString *type = accountSubtypeDictionary[@"type"];
        NSString *subtype = accountSubtypeDictionary[@"subtype"];
        id<PLKAccountSubtype> result = [PlaidFlutterPlugin accountSubtypeFromTypeString:type subtypeString:subtype];
        if (result) {
            [results addObject:result];
        }
    }
    
    return [results copy];
}

+ (id<PLKAccountSubtype>)accountSubtypeFromTypeString:(NSString *)typeString
                                        subtypeString:(NSString *)subtypeString {
    NSString *normalizedTypeString = typeString.lowercaseString;
    NSString *normalizedSubtypeString = subtypeString.lowercaseString;
    if ([normalizedTypeString isEqualToString:@"other"]) {
        if ([normalizedSubtypeString isEqualToString:@"all"]) {
            return [PLKAccountSubtypeOther createWithValue:PLKAccountSubtypeValueOtherAll];
        } else if ([normalizedSubtypeString isEqualToString:@"other"]) {
            return [PLKAccountSubtypeOther createWithValue:PLKAccountSubtypeValueOtherOther];
        } else {
            return [PLKAccountSubtypeOther createWithRawStringValue:normalizedSubtypeString];
        }
    } else if ([normalizedTypeString isEqualToString:@"credit"]) {
        if ([normalizedSubtypeString isEqualToString:@"all"]) {
            return [PLKAccountSubtypeCredit createWithValue:PLKAccountSubtypeValueCreditAll];
        } else if ([normalizedSubtypeString isEqualToString:@"credit card"]) {
            return [PLKAccountSubtypeCredit createWithValue:PLKAccountSubtypeValueCreditCreditCard];
        } else if ([normalizedSubtypeString isEqualToString:@"paypal"]) {
            return [PLKAccountSubtypeCredit createWithValue:PLKAccountSubtypeValueCreditPaypal];
        } else {
            return [PLKAccountSubtypeCredit createWithUnknownValue:subtypeString];
        }
    } else if ([normalizedTypeString isEqualToString:@"loan"]) {
        if ([normalizedSubtypeString isEqualToString:@"all"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanAll];
        } else if ([normalizedSubtypeString isEqualToString:@"auto"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanAuto];
        } else if ([normalizedSubtypeString isEqualToString:@"business"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanBusiness];
        } else if ([normalizedSubtypeString isEqualToString:@"commercial"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanCommercial];
        } else if ([normalizedSubtypeString isEqualToString:@"construction"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanConstruction];
        } else if ([normalizedSubtypeString isEqualToString:@"consumer"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanConsumer];
        } else if ([normalizedSubtypeString isEqualToString:@"home equity"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanHomeEquity];
        } else if ([normalizedSubtypeString isEqualToString:@"line of credit"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanLineOfCredit];
        } else if ([normalizedSubtypeString isEqualToString:@"loan"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanLoan];
        } else if ([normalizedSubtypeString isEqualToString:@"mortgage"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanMortgage];
        } else if ([normalizedSubtypeString isEqualToString:@"overdraft"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanOverdraft];
        } else if ([normalizedSubtypeString isEqualToString:@"student"]) {
            return [PLKAccountSubtypeLoan createWithValue:PLKAccountSubtypeValueLoanStudent];
        } else {
            return [PLKAccountSubtypeLoan createWithUnknownValue:subtypeString];
        }
    } else if ([normalizedTypeString isEqualToString:@"depository"]) {
        if ([normalizedSubtypeString isEqualToString:@"all"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryAll];
        } else if ([normalizedSubtypeString isEqualToString:@"cash management"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryCashManagement];
        } else if ([normalizedSubtypeString isEqualToString:@"cd"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryCd];
        } else if ([normalizedSubtypeString isEqualToString:@"checking"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryChecking];
        } else if ([normalizedSubtypeString isEqualToString:@"ebt"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryEbt];
        } else if ([normalizedSubtypeString isEqualToString:@"hsa"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryHsa];
        } else if ([normalizedSubtypeString isEqualToString:@"money market"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryMoneyMarket];
        } else if ([normalizedSubtypeString isEqualToString:@"paypal"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryPaypal];
        } else if ([normalizedSubtypeString isEqualToString:@"prepaid"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositoryPrepaid];
        } else if ([normalizedSubtypeString isEqualToString:@"savings"]) {
            return [PLKAccountSubtypeDepository createWithValue:PLKAccountSubtypeValueDepositorySavings];
        } else {
            return [PLKAccountSubtypeDepository createWithUnknownValue:subtypeString];
        }

    } else if ([normalizedTypeString isEqualToString:@"investment"]) {
        if ([normalizedSubtypeString isEqualToString:@"all"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentAll];
        } else if ([normalizedSubtypeString isEqualToString:@"401a"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestment401a];
        } else if ([normalizedSubtypeString isEqualToString:@"401k"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestment401k];
        } else if ([normalizedSubtypeString isEqualToString:@"403B"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestment403B];
        } else if ([normalizedSubtypeString isEqualToString:@"457b"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestment457b];
        } else if ([normalizedSubtypeString isEqualToString:@"529"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestment529];
        } else if ([normalizedSubtypeString isEqualToString:@"brokerage"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentBrokerage];
        } else if ([normalizedSubtypeString isEqualToString:@"cash isa"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentCashIsa];
        } else if ([normalizedSubtypeString isEqualToString:@"education savings account"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentEducationSavingsAccount];
        } else if ([normalizedSubtypeString isEqualToString:@"fixed annuity"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentFixedAnnuity];
        } else if ([normalizedSubtypeString isEqualToString:@"gic"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentGic];
        } else if ([normalizedSubtypeString isEqualToString:@"health reimbursement arrangement"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentHealthReimbursementArrangement];
        } else if ([normalizedSubtypeString isEqualToString:@"hsa"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentHsa];
        } else if ([normalizedSubtypeString isEqualToString:@"ira"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentIra];
        } else if ([normalizedSubtypeString isEqualToString:@"isa"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentIsa];
        } else if ([normalizedSubtypeString isEqualToString:@"keogh"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentKeogh];
        } else if ([normalizedSubtypeString isEqualToString:@"lif"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentLif];
        } else if ([normalizedSubtypeString isEqualToString:@"lira"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentLira];
        } else if ([normalizedSubtypeString isEqualToString:@"lrif"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentLrif];
        } else if ([normalizedSubtypeString isEqualToString:@"lrsp"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentLrsp];
        } else if ([normalizedSubtypeString isEqualToString:@"mutual fund"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentMutualFund];
        } else if ([normalizedSubtypeString isEqualToString:@"non-taxable brokerage account"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentNonTaxableBrokerageAccount];
        } else if ([normalizedSubtypeString isEqualToString:@"pension"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentPension];
        } else if ([normalizedSubtypeString isEqualToString:@"plan"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentPlan];
        } else if ([normalizedSubtypeString isEqualToString:@"prif"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentPrif];
        } else if ([normalizedSubtypeString isEqualToString:@"profit sharing plan"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentProfitSharingPlan];
        } else if ([normalizedSubtypeString isEqualToString:@"rdsp"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRdsp];
        } else if ([normalizedSubtypeString isEqualToString:@"resp"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentResp];
        } else if ([normalizedSubtypeString isEqualToString:@"retirement"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRetirement];
        } else if ([normalizedSubtypeString isEqualToString:@"rlif"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRlif];
        } else if ([normalizedSubtypeString isEqualToString:@"roth 401k"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRoth401k];
        } else if ([normalizedSubtypeString isEqualToString:@"roth"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRoth];
        } else if ([normalizedSubtypeString isEqualToString:@"rrif"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRrif];
        } else if ([normalizedSubtypeString isEqualToString:@"rrsp"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentRrsp];
        } else if ([normalizedSubtypeString isEqualToString:@"sarsep"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentSarsep];
        } else if ([normalizedSubtypeString isEqualToString:@"sep ira"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentSepIra];
        } else if ([normalizedSubtypeString isEqualToString:@"simple ira"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentSimpleIra];
        } else if ([normalizedSubtypeString isEqualToString:@"sipp"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentSipp];
        } else if ([normalizedSubtypeString isEqualToString:@"stock plan"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentStockPlan];
        } else if ([normalizedSubtypeString isEqualToString:@"tfsa"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentTfsa];
        } else if ([normalizedSubtypeString isEqualToString:@"thrift savings plan"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentThriftSavingsPlan];
        } else if ([normalizedSubtypeString isEqualToString:@"trust"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentTrust];
        } else if ([normalizedSubtypeString isEqualToString:@"ugma"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentUgma];
        } else if ([normalizedSubtypeString isEqualToString:@"utma"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentUtma];
        } else if ([normalizedSubtypeString isEqualToString:@"variable annuity"]) {
          return [PLKAccountSubtypeInvestment createWithValue:PLKAccountSubtypeValueInvestmentVariableAnnuity];
        } else {
          return [PLKAccountSubtypeInvestment createWithUnknownValue:subtypeString];
        }
    }

    return [PLKAccountSubtypeUnknown createWithRawTypeStringValue:typeString rawSubtypeStringValue:subtypeString];
}

#pragma mark Metadata Parsing

+ (NSDictionary *)dictionaryFromSuccessMetadata:(PLKSuccessMetadata *)metadata {
    return @{@"linkSessionId": metadata.linkSessionID ?: @"",
             @"institution": [PlaidFlutterPlugin dictionaryFromInstitution:metadata.institution] ?: @"",
             @"accounts": [PlaidFlutterPlugin accountsDictionariesFromAccounts:metadata.accounts] ?: @[],
             @"metadataJson": metadata.metadataJSON ?: @"",
    };
}

+ (NSDictionary *)dictionaryFromEventMetadata:(PLKEventMetadata *)metadata {
    return @{@"errorType": [PlaidFlutterPlugin errorTypeStringFromError:metadata.error] ?: @"",
             @"errorCode": [PlaidFlutterPlugin errorCodeStringFromError:metadata.error] ?: @"",
             @"errorMessage": [PlaidFlutterPlugin errorMessageFromError:metadata.error] ?: @"",
             @"exitStatus": [PlaidFlutterPlugin stringForExitStatus:metadata.exitStatus] ?: @"",
             @"institutionId": metadata.institutionID ?: @"",
             @"institutionName": metadata.institutionName ?: @"",
             @"institutionSearchQuery": metadata.institutionSearchQuery ?: @"",
             @"linkSessionId": metadata.linkSessionID ?: @"",
             @"mfaType": [PlaidFlutterPlugin stringForMfaType:metadata.mfaType] ?: @"",
             @"requestId": metadata.requestID ?: @"",
             @"timestamp": [PlaidFlutterPlugin iso8601StringFromDate:metadata.timestamp] ?: @"",
             @"viewName": [PlaidFlutterPlugin stringForViewName:metadata.viewName] ?: @"",
             @"metadataJson": metadata.metadataJSON ?: @"",
    };
}

+ (NSDictionary *)dictionaryFromExitMetadata:(PLKExitMetadata *)metadata {
    return @{@"status": [PlaidFlutterPlugin stringForExitStatus:metadata.status] ?: @"",
             @"institution": [PlaidFlutterPlugin dictionaryFromInstitution:metadata.institution],
             @"requestId": metadata.requestID ?: @"",
             @"linkSessionId": metadata.linkSessionID ?: @"",
             @"metadataJson": metadata.metadataJSON ?: @"",
    };
}

+ (NSDictionary *)dictionaryFromError:(PLKExitError *)error {
    return @{
        @"errorType": [PlaidFlutterPlugin errorTypeStringFromError:error] ?: @"",
        @"errorCode": [PlaidFlutterPlugin errorCodeStringFromError:error] ?: @"",
        @"errorMessage": [PlaidFlutterPlugin errorMessageFromError:error] ?: @"",
        @"errorDisplayMessage": [PlaidFlutterPlugin errorDisplayMessageFromError:error] ?: @"",
    };
}

+ (NSDictionary *)dictionaryFromInstitution:(PLKInstitution *)institution {
    return @{
        @"name": institution.name ?: @"",
        @"id": institution.ID ?: @"",
    };
}

+ (NSDictionary *)dictionaryFromAccount:(PLKAccount *)account {
    NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
    
    [result setObject:account.ID ?: @"" forKey:@"id"];
    [result setObject:account.name ?: @"" forKey:@"name"];
    [result setObject:[PlaidFlutterPlugin subtypeNameForAccountSubtype:account.subtype] ?: @"" forKey:@"subtype"];
    [result setObject:[PlaidFlutterPlugin typeNameForAccountSubtype:account.subtype] ?: @"" forKey:@"type"];
   
    if(account.mask) {
        [result setObject:account.mask forKey:@"mask"];
    }
    
    if (account.verificationStatus) {
        [result setObject:[PlaidFlutterPlugin stringForVerificationStatus:account.verificationStatus] ?: @"" forKey:@"verificationStatus"];
    }
    
    return [result copy];
}

+ (NSArray<NSDictionary *> *)accountsDictionariesFromAccounts:(NSArray<PLKAccount *> *)accounts {
    NSMutableArray<NSDictionary *> *results = [NSMutableArray arrayWithCapacity:accounts.count];
    
    for (PLKAccount *account in accounts) {
        NSDictionary *accountDictionary = [PlaidFlutterPlugin dictionaryFromAccount:account];
        [results addObject:accountDictionary];
    }
    
    return [results copy];
}

+ (NSString *)typeNameForAccountSubtype:(id<PLKAccountSubtype>)accountSubtype {
    if ([accountSubtype isKindOfClass:[PLKAccountSubtypeUnknown class]]) {
        return ((PLKAccountSubtypeUnknown *)accountSubtype).rawStringValue;
    } else if ([accountSubtype isKindOfClass:[PLKAccountSubtypeOther class]]) {
        return @"other";
    } else if ([accountSubtype isKindOfClass:[PLKAccountSubtypeCredit class]]) {
        return @"credit";
    }  else if ([accountSubtype isKindOfClass:[PLKAccountSubtypeLoan class]]) {
        return @"loan";
    }  else if ([accountSubtype isKindOfClass:[PLKAccountSubtypeDepository class]]) {
        return @"depository";
    }  else if ([accountSubtype isKindOfClass:[PLKAccountSubtypeInvestment class]]) {
        return @"investment";
    }
    return @"unknown";
}

+ (NSString *)subtypeNameForAccountSubtype:(id<PLKAccountSubtype>)accountSubtype {
    if ([accountSubtype isKindOfClass:[PLKAccountSubtypeUnknown class]]) {
        return ((PLKAccountSubtypeUnknown *)accountSubtype).rawSubtypeStringValue;
    }
    return accountSubtype.rawStringValue;
}

+ (NSString *)stringForEventName:(PLKEventName *)eventName {
    if (!eventName) {
        return @"";
    }
    
    if (eventName.unknownStringValue) {
        return eventName.unknownStringValue;
    }

    switch (eventName.value) {
        case PLKEventNameValueNone:
            return @"";
        case PLKEventNameValueBankIncomeInsightsCompleted:
            return @"BANK_INCOME_INSIGHTS_COMPLETED";
        case PLKEventNameValueCloseOAuth:
            return @"CLOSE_OAUTH";
        case PLKEventNameValueError:
            return @"ERROR";
        case PLKEventNameValueExit:
            return @"EXIT";
        case PLKEventNameValueFailOAuth:
            return @"FAIL_OAUTH";
        case PLKEventNameValueHandoff:
            return @"HANDOFF";
        case PLKEventNameValueIdentityVerificationStartStep:
            return @"IDENTITY_VERIFICATION_START_STEP";
        case PLKEventNameValueIdentityVerificationPassStep:
            return @"IDENTITY_VERIFICATION_PASS_STEP";
        case PLKEventNameValueIdentityVerificationFailStep:
            return @"IDENTITY_VERIFICATION_FAIL_STEP";
        case PLKEventNameValueIdentityVerificationPendingReviewStep:
            return @"IDENTITY_VERIFICATION_PENDING_REVIEW_STEP";
        case PLKEventNameValueIdentityVerificationCreateSession:
            return @"IDENTITY_VERIFICATION_CREATE_SESSION";
        case PLKEventNameValueIdentityVerificationResumeSession:
            return @"IDENTITY_VERIFICATION_RESUME_SESSION";
        case PLKEventNameValueIdentityVerificationPassSession:
            return @"IDENTITY_VERIFICATION_PASS_SESSION";
        case PLKEventNameValueIdentityVerificationFailSession:
            return @"IDENTITY_VERIFICATION_FAIL_SESSION";
        case PLKEventNameValueIdentityVerificationOpenUI:
            return @"IDENTITY_VERIFICATION_OPEN_UI";
        case PLKEventNameValueIdentityVerificationResumeUI:
            return @"IDENTITY_VERIFICATION_RESUME_UI";
        case PLKEventNameValueIdentityVerificationCloseUI:
            return @"IDENTITY_VERIFICATION_CLOSE_UI";
        case PLKEventNameValueMatchedSelectInstitution:
            return @"MATCHED_SELECT_INSTITUTION";
        case PLKEventNameValueMatchedSelectVerifyMethod:
            return @"MATCHED_SELECT_VERIFY_METHOD";
        case PLKEventNameValueOpen:
            return @"OPEN";
        case PLKEventNameValueOpenMyPlaid:
            return @"OPEN_MY_PLAID";
        case PLKEventNameValueOpenOAuth:
            return @"OPEN_OAUTH";
        case PLKEventNameValueSearchInstitution:
            return @"SEARCH_INSTITUTION";
        case PLKEventNameValueSelectInstitution:
            return @"SELECT_INSTITUTION";
        case PLKEventNameValueSubmitCredentials:
            return @"SUBMIT_CREDENTIALS";
        case PLKEventNameValueSubmitMFA:
            return @"SUBMIT_MFA";
        case PLKEventNameValueTransitionView:
            return @"TRANSITION_VIEW";
        case PLKEventNameValueSelectDegradedInstitution:
            return @"SELECT_DEGRADED_INSTITUTION";
        case PLKEventNameValueSelectDownInstitution:
            return @"SELECT_DOWN_INSTITUTION";
    }
     return @"unknown";
}

+ (NSString *)stringForMfaType:(PLKMFAType)mfaType {
    switch (mfaType) {
        case PLKMFATypeNone:
            return @"";
        case PLKMFATypeCode:
            return @"code";
        case PLKMFATypeDevice:
            return @"device";
        case PLKMFATypeQuestions:
            return @"questions";
        case PLKMFATypeSelections:
            return @"selections";
    }

    return @"unknown";
}

+ (NSString *)stringForExitStatus:(PLKExitStatus *)exitStatus {
    if (!exitStatus) {
        return @"";
    }

    if (exitStatus.unknownStringValue) {
        return exitStatus.unknownStringValue;
    }

    switch (exitStatus.value) {
        case PLKExitStatusValueNone:
            return @"";
        case PLKExitStatusValueRequiresQuestions:
            return @"requires_questions";
        case PLKExitStatusValueRequiresSelections:
            return @"requires_selections";
        case PLKExitStatusValueRequiresCode:
            return @"requires_code";
        case PLKExitStatusValueChooseDevice:
            return @"choose_device";
        case PLKExitStatusValueRequiresCredentials:
            return @"requires_credentials";
        case PLKExitStatusValueInstitutionNotFound:
            return @"institution_not_found";
        case PLKExitStatusValueRequiresAccountSelection:
            return @"requires_account_selection";
    }
    return @"unknown";
}

+ (NSString *)stringForViewName:(PLKViewName *)viewName {
    if (!viewName) {
        return @"";
    }

    if (viewName.unknownStringValue) {
        return viewName.unknownStringValue;
    }

    switch (viewName.value) {
        case PLKViewNameValueNone:
            return @"";
        case PLKViewNameValueAcceptTOS:
            return @"ACCEPT_TOS";
        case PLKViewNameValueConnected:
            return @"CONNECTED";
        case PLKViewNameValueConsent:
            return @"CONSENT";
        case PLKViewNameValueCredential:
            return @"CREDENTIAL";
        case PLKViewNameValueDocumentaryVerification:
            return @"DOCUMENTARY_VERIFICATION";
        case PLKViewNameValueError:
            return @"ERROR";
        case PLKViewNameValueExit:
            return @"EXIT";
        case PLKViewNameValueKYCCheck:
            return @"KYC_CHECK";
        case PLKViewNameValueLoading:
            return @"LOADING";
        case PLKViewNameValueMatchedConsent:
            return @"MATCHED_CONSENT";
        case PLKViewNameValueMatchedCredential:
            return @"MATCHED_CREDENTIAL";
        case PLKViewNameValueMatchedMFA:
            return @"MATCHED_MFA";
        case PLKViewNameValueMFA:
            return @"MFA";
        case PLKViewNameValueNumbers:
            return @"NUMBERS";
        case PLKViewNameValueOauth:
            return @"OAUTH";
        case PLKViewNameValueRecaptcha:
            return @"RECAPTCHA";
        case PLKViewNameValueRiskCheck:
            return @"RISK_CHECK";
        case PLKViewNameValueScreening:
            return @"SCREENING";
        case PLKViewNameValueSelectAccount:
            return @"SELECT_ACCOUNT";
        case PLKViewNameValueSelectInstitution:
            return @"SELECT_INSTITUTION";
        case PLKViewNameValueSelfieCheck:
            return @"SELFIE_CHECK";
        case PLKViewNameValueSubmitDocuments:
            return @"SUBMIT_DOCUMENTS";
        case PLKViewNameValueSubmitDocumentsSuccess:
            return @"SUBMIT_DOCUMENTS_SUCCESS";
        case PLKViewNameValueSubmitDocumentsError:
            return @"SUBMIT_DOCUMENTS_ERROR";
        case PLKViewNameValueUploadDocuments:
            return @"UPLOAD_DOCUMENTS";
        case PLKViewNameValueVerifySMS:
            return @"VERIFY_SMS";
    }

    return @"unknown";
}

+ (NSString *)stringForVerificationStatus:(PLKVerificationStatus *)verificationStatus {
    if (!verificationStatus) {
        return @"";
    }

    if (verificationStatus.unknownStringValue) {
        return verificationStatus.unknownStringValue;
    }

    switch (verificationStatus.value) {
        case PLKVerificationStatusValueNone:
            return @"";
        case PLKVerificationStatusValuePendingAutomaticVerification:
            return @"pending_automatic_verification";
        case PLKVerificationStatusValuePendingManualVerification:
            return @"pending_manual_verification";
        case PLKVerificationStatusValueManuallyVerified:
            return @"manually_verified";
    }

    return @"unknown";
}

+ (NSString *)errorDisplayMessageFromError:(PLKExitError *)error {
    return error.userInfo[kPLKExitErrorDisplayMessageKey] ?: @"";
}

+ (NSString *)errorTypeStringFromError:(PLKExitError *)error {
    NSString *errorDomain = error.domain;
    if (!error || !errorDomain) {
        return @"";
    }
    
    NSString *normalizedErrorDomain = errorDomain;
    
    return @{
        kPLKExitErrorInvalidRequestDomain: @"INVALID_REQUEST",
        kPLKExitErrorInvalidInputDomain: @"INVALID_INPUT",
        kPLKExitErrorInstitutionErrorDomain: @"INSTITUTION_ERROR",
        kPLKExitErrorRateLimitExceededDomain: @"RATE_LIMIT_EXCEEDED",
        kPLKExitErrorApiDomain: @"API_ERROR",
        kPLKExitErrorItemDomain: @"ITEM_ERROR",
        kPLKExitErrorAuthDomain: @"AUTH_ERROR",
        kPLKExitErrorAssetReportDomain: @"ASSET_REPORT_ERROR",
        kPLKExitErrorInternalDomain: @"INTERNAL",
        kPLKExitErrorUnknownDomain: error.userInfo[kPLKExitErrorUnknownTypeKey] ?: @"UNKNOWN",
    }[normalizedErrorDomain] ?: @"UNKNOWN";
}

+ (NSString *)errorCodeStringFromError:(PLKExitError *)error {
   NSString *errorDomain = error.domain;

    if (!error || !errorDomain) {
        return @"";
    }
    return error.userInfo[kPLKExitErrorCodeKey];
}

+ (NSString *)errorMessageFromError:(PLKExitError *)error {
    return error.userInfo[kPLKExitErrorMessageKey] ?: @"";
}

+ (NSString *)iso8601StringFromDate:(NSDate *)date {
    NSTimeZone *timeZone = [NSTimeZone timeZoneWithAbbreviation: @"GMT"];
    NSISO8601DateFormatOptions options = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithDashSeparatorInDate | NSISO8601DateFormatWithColonSeparatorInTime | NSISO8601DateFormatWithTimeZone;

    return [NSISO8601DateFormatter stringFromDate:date timeZone:timeZone formatOptions:options];
}

@end

