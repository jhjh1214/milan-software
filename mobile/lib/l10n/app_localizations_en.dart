// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class LEn extends L {
  LEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Milan Quote';

  @override
  String get languageChinese => '中文';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageMalay => 'Bahasa Melayu';

  @override
  String get language => 'Language';

  @override
  String get quoteTitle => 'Quotation';

  @override
  String get newQuote => 'New quotation';

  @override
  String get addWindow => 'Add window';

  @override
  String get emptyQuoteTitle => 'No windows yet';

  @override
  String get emptyQuoteAction => 'Tap below to add the first window';

  @override
  String get stepRoom => 'Which room?';

  @override
  String get stepProduct => 'Which product?';

  @override
  String get stepMaterial => 'Which material?';

  @override
  String get stepSizes => 'Sizes';

  @override
  String get stepUpgrade => 'Add anything?';

  @override
  String get upgradeNone => 'No, that is all';

  @override
  String get upgradeIncluded =>
      'A normal track is already included. These are upgrades.';

  @override
  String get upgradeRequired => 'Required for this product, and priced below';

  @override
  String upgradeAdded(String name) {
    return 'Added $name';
  }

  @override
  String upgradeOf(String parent) {
    return 'with $parent';
  }

  @override
  String get stepFamily => 'Which category?';

  @override
  String get familyCurtain => 'Curtains';

  @override
  String get familyBlind => 'Blinds';

  @override
  String get familyTrack => 'Tracks & rods';

  @override
  String get familyFlooring => 'Flooring';

  @override
  String get familyWallpaper => 'Wallpaper';

  @override
  String get familyAddon => 'Add-ons';

  @override
  String get familyService => 'Services';

  @override
  String get materialLater => 'Material chosen at measurement';

  @override
  String get materialLaterNote =>
      'Quoted at the dearest material. A cheaper choice lowers this.';

  @override
  String get wallpaperMeasureHint =>
      'Optional — enter the wall size to check whether more than one pack is needed';

  @override
  String get wallpaperUnmeasured => 'not measured';

  @override
  String stepProgress(int current, int total, String room) {
    return 'Window $current of $total · $room';
  }

  @override
  String get roomLiving => 'Living room';

  @override
  String get roomMaster => 'Master bedroom';

  @override
  String get roomBedroom => 'Bedroom';

  @override
  String get roomKitchen => 'Kitchen';

  @override
  String get roomBalcony => 'Balcony';

  @override
  String get roomStudy => 'Study';

  @override
  String get roomOther => 'Other';

  @override
  String get roomCustom => 'Type a name';

  @override
  String get width => 'Width';

  @override
  String get height => 'Height';

  @override
  String get lengthDimension => 'Length';

  @override
  String get dropDimension => 'Drop';

  @override
  String get quantity => 'Quantity';

  @override
  String sameWindows(int count) {
    return '$count identical windows';
  }

  @override
  String get unitFoot => 'ft';

  @override
  String get unitInch => 'in';

  @override
  String get unitMm => 'mm';

  @override
  String get unitCm => 'cm';

  @override
  String get unitMetre => 'm';

  @override
  String get unitSqft => 'sqft';

  @override
  String get unitPack => 'pack';

  @override
  String billedAs(String qty, String unit) {
    return 'billed as $qty $unit';
  }

  @override
  String enteredAs(String value) {
    return 'entered $value';
  }

  @override
  String minQtyApplied(String qty, String unit) {
    return 'minimum $qty $unit';
  }

  @override
  String get errorInvalidDimension => 'That size cannot be read';

  @override
  String get errorDimensionRequired => 'Enter a size';

  @override
  String get errorNoRate =>
      'This product has no complete rate. Tell the office.';

  @override
  String warnUnitLooksWrong(
    String value,
    String unit,
    String converted,
    String suggestion,
  ) {
    return '$value $unit = $converted. Did you mean $suggestion?';
  }

  @override
  String warnSwitchTo(String unit) {
    return 'Change to $unit';
  }

  @override
  String warnDropVeryShort(String value) {
    return 'Height is only $value. Is that right?';
  }

  @override
  String warnNearBandEdge(String edge) {
    return 'Just over $edge. Please check the size.';
  }

  @override
  String warnImplausibleSize(Object size) {
    return 'That is $size. Please check the size and the unit.';
  }

  @override
  String get measureTitle => 'Site measurement';

  @override
  String get measureEstimated => 'Quoted';

  @override
  String get measureFinal => 'After measurement';

  @override
  String get measureNotYetPriced => 'Not yet priced';

  @override
  String get measureEstimatedSize => 'Quoted';

  @override
  String get measureMeasuredSize => 'Measured';

  @override
  String get measureThis => 'Measure';

  @override
  String get measureAgain => 'Measure again';

  @override
  String measureQuotedAs(Object size) {
    return 'Quoted as $size';
  }

  @override
  String measureWasQuoted(Object size) {
    return 'Quoted $size';
  }

  @override
  String get measureChooseMaterial => 'Choose the material';

  @override
  String measureUnderEstimate(Object amount) {
    return '$amount below the quote';
  }

  @override
  String measureOverEstimate(Object amount) {
    return '$amount ABOVE the quote — check the sizes';
  }

  @override
  String measureOutstanding(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines still to finish',
      one: '1 line still to finish',
    );
    return '$_temp0';
  }

  @override
  String get measureRefusedNotMeasured => 'Not measured yet.';

  @override
  String get measureRefusedMaterial => 'Material not chosen yet.';

  @override
  String get measureRefusedNoCard =>
      'This handset does not have the price list this line was quoted from. Connect once and try again — it will not be priced at today\'s rates.';

  @override
  String get measureRefusedNoRate =>
      'No rate on the held list matches this line.';

  @override
  String get measureRefusedZero =>
      'That is not a measurement. Check the number.';

  @override
  String get measureRefusedTerminal => 'This order is closed or cancelled.';

  @override
  String get measureRefusedNoLine => 'That line is not on this order.';

  @override
  String warnBandBothPrices(String lower, String lowerPrice, String upper) {
    return 'Up to $lower: $lowerPrice · Over $upper';
  }

  @override
  String get runningTotal => 'Total';

  @override
  String get customerTitle => 'Customer';

  @override
  String get customerName => 'Customer name';

  @override
  String get customerPhone => 'Phone';

  @override
  String get customerOptional => 'Optional — can be filled in later';

  @override
  String get deliveryTitle => 'Delivery area';

  @override
  String get deliveryNone => 'Melaka town (no charge)';

  @override
  String deliveryCharge(String area) {
    return 'Travel $area';
  }

  @override
  String get deliveryAskEarly => 'Asked before the total, never after';

  @override
  String get save => 'Save';

  @override
  String get ratesTitle => 'Price list';

  @override
  String get ratesEditOne => 'Change one price';

  @override
  String get ratesSearch => 'Search products';

  @override
  String get ratesNewRate => 'New rate (RM)';

  @override
  String get ratesNewMvp => 'MVP rate (RM)';

  @override
  String ratesCurrent(String rate) {
    return 'Now $rate';
  }

  @override
  String get ratesInvalid => 'That is not a price';

  @override
  String get ratesMvpTooHigh =>
      'The MVP rate cannot be above the standard rate';

  @override
  String get ratesNoMatch => 'No product found';

  @override
  String ratesVersion(int version, int count) {
    return 'Version $version · $count products';
  }

  @override
  String get ratesExport => 'Export for Excel';

  @override
  String get ratesImport => 'Import edited file';

  @override
  String get ratesNoChanges => 'No price changes';

  @override
  String ratesReview(int count) {
    return '$count prices would change. Nothing is applied until you confirm.';
  }

  @override
  String get ratesApply => 'Apply these prices';

  @override
  String ratesApplied(int version) {
    return 'Prices updated to version $version';
  }

  @override
  String get ratesErrors => 'The file has problems. No prices were changed.';

  @override
  String get ratesRestore => 'Restore the original price list';

  @override
  String ratesCustom(int version) {
    return 'Price list has been edited (version $version)';
  }

  @override
  String get share => 'Share quotation';

  @override
  String get pdfTitle => 'Quotation';

  @override
  String get pdfCompany => 'Milan Curtain & Flooring';

  @override
  String get pdfQuoteNo => 'Quotation no.';

  @override
  String get pdfDate => 'Date';

  @override
  String get pdfRoom => 'Room';

  @override
  String get pdfProduct => 'Product';

  @override
  String get pdfSize => 'Size';

  @override
  String get pdfBilled => 'Billed';

  @override
  String get pdfRate => 'Rate';

  @override
  String get pdfAmount => 'Amount';

  @override
  String get pdfNotAnInvoice =>
      'This document is a quotation, not a tax invoice.';

  @override
  String pdfValidity(int days) {
    return 'Valid for $days days';
  }

  @override
  String pdfPage(int page, int total) {
    return 'Page $page of $total';
  }

  @override
  String get subtotal => 'Subtotal';

  @override
  String get lineTotal => 'Line total';

  @override
  String depositFloorRow(String amount) {
    return 'Minimum quotation (deposit $amount)';
  }

  @override
  String get depositFloorExplain =>
      'A quotation is never less than the deposit, so the deposit can never exceed the order.';

  @override
  String get disclaimerTitle => 'Reference price';

  @override
  String get disclaimerBody =>
      'This quotation is rounded up to whole units and is for reference only. After on-site measurement the final price will be the same or lower, never higher.';

  @override
  String get revisedTitle => 'Revised order — after site measurement';

  @override
  String get revisedOrderNo => 'Order no.';

  @override
  String get revisedPendingSync => 'pending sync';

  @override
  String get revisedQuotedOn => 'Quoted';

  @override
  String get revisedMeasuredOn => 'Measured';

  @override
  String get revisedColQuoted => 'Quoted';

  @override
  String get revisedColMeasured => 'Measured';

  @override
  String get revisedColQuotedAmount => 'Quoted';

  @override
  String get revisedColFinalAmount => 'Final';

  @override
  String get revisedColChange => 'Change';

  @override
  String get revisedEstimateTotal => 'Quoted total';

  @override
  String get revisedFinalTotal => 'Final total';

  @override
  String get revisedYouSave => 'Reduced by';

  @override
  String get revisedNoChange => 'Unchanged';

  @override
  String revisedMinimumCharge(String amount) {
    return 'Minimum charge (deposit $amount)';
  }

  @override
  String get revisedDepositPaid => 'Deposit paid';

  @override
  String get revisedBalanceDue => 'Balance due';

  @override
  String get revisedWhyTitle => 'Why this differs from your quotation';

  @override
  String get revisedWhyBody =>
      'The quotation rounded every measurement up to a whole unit. This document uses the exact site measurement, so the price is the same or lower.';

  @override
  String get revisedOverTitle =>
      'One or more windows measured larger than quoted';

  @override
  String get revisedOverBody =>
      'The sizes below came out bigger on site than the sizes given at the time of quotation, so those lines cost more. Everything else is unchanged. Please check them with us.';

  @override
  String revisedOverAmount(String amount) {
    return '$amount more than quoted';
  }

  @override
  String revisedPricedAt(int version) {
    return 'Priced at price list version $version';
  }

  @override
  String get revisedNotAnInvoice =>
      'This document is a revised order confirmation, not a tax invoice.';

  @override
  String revisedIncomplete(num count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count lines are not priced',
      one: '1 line is not priced',
    );
    return 'This order cannot be printed yet — $_temp0.';
  }

  @override
  String get revisedShare => 'Share revised order';

  @override
  String get provisionalCardBanner =>
      'Rate card not confirmed. Do not quote a customer.';

  @override
  String listFair(String code) {
    return 'Fair prices $code';
  }

  @override
  String get listStandard => 'Standard prices (not a fair)';

  @override
  String get listStandardProvisional =>
      'Standard prices are provisional: curtains +20%, blinds +50%. Everything else costs the same all year.';

  @override
  String expiredCardBanner(String code, String date) {
    return 'These are $code fair rates and they expired on $date. Not valid for everyday quoting.';
  }

  @override
  String get delete => 'Delete';

  @override
  String get deleted => 'Deleted';

  @override
  String get undo => 'Undo';

  @override
  String get back => 'Back';

  @override
  String get next => 'Next';

  @override
  String get done => 'Done';

  @override
  String get cancel => 'Cancel';

  @override
  String get confirm => 'Confirm';

  @override
  String get keypadClear => 'Clear';

  @override
  String get keypadBackspace => 'Backspace';

  @override
  String get keypadDone => 'OK';

  @override
  String get bandLower => 'Up to 10ft';

  @override
  String get bandUpper => 'Over 10ft';

  @override
  String get tierMvp => 'MVP rate';

  @override
  String get tierStandard => 'Standard rate';

  @override
  String get roleAdmin => 'Admin';

  @override
  String get roleStaff => 'Staff';

  @override
  String get roleParttime => 'Part-timer';

  @override
  String get syncTitle => 'Sync';

  @override
  String get signInTitle => 'Sign in';

  @override
  String get signInPhone => 'Phone number';

  @override
  String get signInPin => 'PIN';

  @override
  String get signInAction => 'Sign in';

  @override
  String get signInFailed => 'Phone or PIN is wrong';

  @override
  String get signInOffline => 'No connection. Try again when you have signal.';

  @override
  String signInBusy(int seconds) {
    return 'Too many tries. Wait $seconds seconds.';
  }

  @override
  String get signInWhy =>
      'Sign in once before the fair. The app keeps working offline afterwards.';

  @override
  String signedInAs(String name, String role) {
    return 'Signed in as $name ($role)';
  }

  @override
  String get signOut => 'Sign out';

  @override
  String get notSignedIn =>
      'Not signed in. Quoting still works; nothing is sent to the office.';

  @override
  String get serverAddress => 'Server address';

  @override
  String get serverAddressInvalid =>
      'Enter an https address, for example milan.example.com';

  @override
  String get serverAddressChanged => 'Server changed. Sign in again.';

  @override
  String get syncNow => 'Sync now';

  @override
  String get syncRunning => 'Syncing';

  @override
  String get syncNever => 'Not synced yet';

  @override
  String syncLastAt(String time) {
    return 'Last synced $time';
  }

  @override
  String get syncOffline =>
      'No connection. Everything still works; this will catch up later.';

  @override
  String get syncSignedOut =>
      'This handset was signed out. Sign in again to send quotes.';

  @override
  String syncPricesUpdated(int version) {
    return 'Prices updated to version $version';
  }

  @override
  String get syncPricesCurrent => 'Prices are up to date';

  @override
  String syncQueued(int count) {
    return '$count quotes waiting to send';
  }

  @override
  String syncSent(int count) {
    return '$count quotes sent';
  }

  @override
  String syncParked(int count) {
    return '$count quotes need attention';
  }

  @override
  String syncDisagreed(int count) {
    return '$count quotes were priced differently by the office. They were accepted and flagged for review.';
  }

  @override
  String get syncLocalEditDropped =>
      'The prices edited on this phone were replaced by the office list.';

  @override
  String pricesFromServer(String time) {
    return 'Prices from the office, as of $time';
  }

  @override
  String get pricesBundled =>
      'Prices as shipped with the app. Sign in to get the office list.';

  @override
  String get pricesLocal =>
      'Prices edited on this phone. They will be replaced on the next sync.';

  @override
  String get ratesServerOwned =>
      'Prices come from the office so every handset quotes the same. A change made here is published to everyone.';

  @override
  String get ratesPublish => 'Publish to everyone';

  @override
  String ratesPublished(int version) {
    return 'Published version $version. Every handset picks it up on its next sync.';
  }

  @override
  String get ratesPublishOffline =>
      'Publishing needs a connection, so that every handset gets the same list.';

  @override
  String get ratesReadOnly => 'Only the office can change prices.';

  @override
  String get ratesCheckUpdates => 'Check for updates';

  @override
  String get fairModeTitle => 'Fair mode';

  @override
  String get fairModePrepare => 'Get ready for a fair';

  @override
  String get fairModeWhy =>
      'Downloads both price lists and empties the queue, so the phone works for days with no signal.';

  @override
  String get fairModeReady =>
      'Ready. Both price lists are current and nothing is waiting to send.';

  @override
  String get fairModeNotReady =>
      'Not ready yet. Connect and try again before you leave.';

  @override
  String get atFair => 'At a fair';

  @override
  String get atFairHelp =>
      'Fair prices, and RM300 holds them for 12 months. Turns itself off when the fair ends.';

  @override
  String atFairEnded(String date) {
    return 'The fair ended on $date. These are standard prices.';
  }

  @override
  String get channelFair => 'Fair';

  @override
  String get channelShowroom => 'Showroom';

  @override
  String depositNeededTitle(String category) {
    return 'This order has $category';
  }

  @override
  String depositNeededBody(String category, String amount) {
    return '$category needs its own $amount to hold the promo price for 12 months.';
  }

  @override
  String depositCollect(String amount) {
    return 'Take $amount';
  }

  @override
  String get depositDecline => 'No hold, today\'s price';

  @override
  String depositRemove(String category) {
    return 'Remove $category';
  }

  @override
  String depositCollected(String amount, String category, String date) {
    return '$amount recorded. $category held until $date.';
  }

  @override
  String depositDeclined(String category) {
    return 'Noted. $category is not held.';
  }

  @override
  String get depositNotAtFair => 'Only RM300 paid at a fair can hold a price.';

  @override
  String get categoryCurtain => 'curtains';

  @override
  String get categoryFlooring => 'flooring';

  @override
  String get categoryWallpaper => 'wallpaper';

  @override
  String get paymentMethodTitle => 'How was it paid?';

  @override
  String get methodCash => 'Cash';

  @override
  String get methodCard => 'Card terminal';

  @override
  String get methodDuitnow => 'DuitNow';

  @override
  String get methodTransfer => 'Bank transfer';

  @override
  String get methodCheque => 'Cheque';

  @override
  String get receiptPending => 'Receipt number pending sync';

  @override
  String paymentsTaken(String amount) {
    return '$amount taken';
  }

  @override
  String get cashUpTitle => 'Money taken today';

  @override
  String get cashUpExpected => 'Should have';

  @override
  String get cashUpCounted => 'Counted';

  @override
  String get cashUpShort => 'short by';

  @override
  String get cashUpOver => 'over by';

  @override
  String get cashUpBalanced => 'Everything matches.';

  @override
  String get cashUpNothingTaken => 'No money taken yet today.';

  @override
  String cashUpNotCounted(int count) {
    return '$count cash total not counted yet. It only counts once you count it.';
  }

  @override
  String cashUpOff(String method, String amount, String direction) {
    return '$method is $direction $amount.';
  }

  @override
  String get orderConfirmed => 'Order confirmed';

  @override
  String get orderNoPending => 'Order number pending sync';

  @override
  String orderPaidAndDue(String paid, String balance) {
    return 'Paid $paid · $balance to go';
  }

  @override
  String get orderDueNote =>
      'Against the estimate. After measuring it can only stay the same or fall.';

  @override
  String orderDepositTaken(String amount) {
    return 'Deposit $amount taken';
  }

  @override
  String orderRateLocked(String category, String date) {
    return '$category promo rate held until $date';
  }

  @override
  String orderRateReference(int version) {
    return 'Billed at the rates in force then (list version $version).';
  }

  @override
  String get orderMeasureNext => 'The actual price comes after measuring.';

  @override
  String get statusConfirmed => 'Confirmed';

  @override
  String get statusMeasurementBooked => 'Measurement booked';

  @override
  String get statusMeasured => 'Measured';

  @override
  String get statusMaterialSelected => 'Material chosen';

  @override
  String get statusInProduction => 'In production';

  @override
  String get statusReady => 'Ready to install';

  @override
  String get statusInstalled => 'Installed';

  @override
  String get statusClosed => 'Closed';

  @override
  String get statusCancelled => 'Cancelled';

  @override
  String get orderTitle => 'Order';

  @override
  String get orderHistory => 'What has happened';

  @override
  String get orderLines => 'What was ordered';

  @override
  String orderAdvanceTo(String status) {
    return 'Mark as $status';
  }

  @override
  String get orderNothingLeft => 'Nothing left to do on this order.';

  @override
  String get orderCancelAction => 'Cancel this order';

  @override
  String get orderCancelTitle => 'Cancel this order?';

  @override
  String get orderCancelReason => 'Why is it being cancelled?';

  @override
  String get orderCancelHint => 'At least 4 letters. This is the record.';

  @override
  String get orderCancelConfirm => 'Cancel the order';

  @override
  String get orderKeep => 'Keep it';

  @override
  String get orderCancelDepositNote =>
      'The deposit stays on the record. Whether it is refunded is settled off the app.';

  @override
  String orderEventBy(String name) {
    return 'by $name';
  }

  @override
  String get orderRefusedNotATransition =>
      'That is not the next step from here.';

  @override
  String get orderRefusedTerminal =>
      'This order is finished. Nothing more moves.';

  @override
  String get orderRefusedLinesNotMeasured =>
      'Some windows still have no measurements.';

  @override
  String get orderRefusedMaterialNotChosen =>
      'Some lines still have no material chosen.';

  @override
  String get orderRefusedBuyerDetails =>
      'This order is over RM10,000. Take the customer\'s details before it goes any further.';

  @override
  String get orderRefusedNoReason =>
      'Write a reason first, at least 4 letters.';

  @override
  String get buyerTitle => 'Customer details for the invoice';

  @override
  String buyerWhyOverThreshold(String amount) {
    return 'This order is over $amount. By law the invoice needs the customer\'s own details — a company cannot issue it to \"cash sale\".';
  }

  @override
  String buyerWhyNearThreshold(String amount) {
    return 'This order is close to $amount. If it goes over after measurement the invoice will need these, and by then the customer has gone home. Take them now.';
  }

  @override
  String get buyerWhyRequested =>
      'The customer asked for an e-invoice, so these are needed whatever the amount.';

  @override
  String get buyerStillNeeded => 'Still needed';

  @override
  String get buyerComplete => 'Everything needed is here.';

  @override
  String get buyerMissingName =>
      'The customer\'s full name, as it appears on their IC or company registration';

  @override
  String get buyerMissingIdentifier => 'A TIN, or an ID number with its type';

  @override
  String get buyerMissingAddress =>
      'A full address — street, city, state and postcode';

  @override
  String get buyerName => 'Full name';

  @override
  String get buyerNameHint =>
      'As on the IC or the company registration, not a nickname';

  @override
  String get buyerIdentifierSection => 'Identification';

  @override
  String get buyerIdentifierNote =>
      'A TIN is enough on its own. Otherwise give an ID number AND say which kind it is — a number with no type cannot be filed.';

  @override
  String get buyerTin => 'TIN';

  @override
  String get buyerIdType => 'ID type';

  @override
  String get buyerIdNumber => 'ID number';

  @override
  String get buyerIdTypeNric => 'NRIC (IC)';

  @override
  String get buyerIdTypeBrn => 'Company (BRN)';

  @override
  String get buyerIdTypePassport => 'Passport';

  @override
  String get buyerIdTypeArmy => 'Army / police';

  @override
  String get buyerAddressSection => 'Address';

  @override
  String get buyerAddress1 => 'Address line 1';

  @override
  String get buyerAddress2 => 'Address line 2';

  @override
  String get buyerCity => 'City';

  @override
  String get buyerState => 'State';

  @override
  String get buyerPostcode => 'Postcode';

  @override
  String get buyerMsic => 'MSIC code';

  @override
  String get buyerMsicNote => 'Business buyers only. Leave blank for a person.';

  @override
  String get buyerRequested => 'The customer asked for an e-invoice';

  @override
  String get buyerSave => 'Save details';

  @override
  String get buyerSaved => 'Details saved';

  @override
  String get buyerEdit => 'Customer details';

  @override
  String get buyerNotAnInvoice =>
      'These are collected so the invoice can be issued in the accounts system. This app does not issue invoices.';

  @override
  String get overrideTitle => 'Change this price';

  @override
  String overrideCurrent(String amount) {
    return 'Now $amount';
  }

  @override
  String get overrideNewTotal => 'New total';

  @override
  String get overrideReason => 'Why?';

  @override
  String get overrideHint =>
      'At least 4 letters. Every change is recorded against your name.';

  @override
  String get overrideApply => 'Change it';

  @override
  String get overrideMarker => 'Price changed by hand';

  @override
  String get overrideRefusedNotAnAdmin => 'Only an admin can change a price.';

  @override
  String get overrideRefusedNoReason =>
      'Write a reason first, at least 4 letters.';

  @override
  String get overrideRefusedNegativeTotal =>
      'A line cannot cost less than nothing.';

  @override
  String get overrideRefusedNoChange => 'That is the price already.';

  @override
  String get overrideRefusedOrderFinished =>
      'This order is finished. Its prices no longer move.';

  @override
  String get overridesThisWeek => 'Prices changed this week';

  @override
  String get overridesNone => 'Nobody changed a price this week.';

  @override
  String overrideRow(String before, String after, String name) {
    return '$before to $after, by $name';
  }

  @override
  String get declinesTitle => 'Deposits asked for';

  @override
  String get declinesNone => 'Nobody was asked for a deposit in this period.';

  @override
  String declinesAsked(int count) {
    return 'Asked $count times';
  }

  @override
  String declinesTook(int count) {
    return 'Took $count';
  }

  @override
  String declinesSaidNo(int count) {
    return '$count said no';
  }

  @override
  String declinesDismissed(int count) {
    return '$count never answered';
  }

  @override
  String declinesRemoved(int count) {
    return '$count took the lines off';
  }

  @override
  String declinesLeftOnTable(String amount) {
    return '$amount quoted and not deposited on';
  }

  @override
  String declinesTakeRate(int percent) {
    return '$percent% of the answers were money';
  }
}
