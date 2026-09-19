import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_am.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('am'),
    Locale('en')
  ];

  /// No description provided for @appTitle.
  ///
  /// In en, this message translates to:
  /// **'Smart Home Ethiopia'**
  String get appTitle;

  /// No description provided for @login.
  ///
  /// In en, this message translates to:
  /// **'Login'**
  String get login;

  /// No description provided for @register.
  ///
  /// In en, this message translates to:
  /// **'Register'**
  String get register;

  /// No description provided for @email.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get email;

  /// No description provided for @password.
  ///
  /// In en, this message translates to:
  /// **'Password'**
  String get password;

  /// No description provided for @fullName.
  ///
  /// In en, this message translates to:
  /// **'Full Name'**
  String get fullName;

  /// No description provided for @phone.
  ///
  /// In en, this message translates to:
  /// **'Phone'**
  String get phone;

  /// No description provided for @dashboard.
  ///
  /// In en, this message translates to:
  /// **'My Home'**
  String get dashboard;

  /// No description provided for @addDevice.
  ///
  /// In en, this message translates to:
  /// **'Add Device'**
  String get addDevice;

  /// No description provided for @settings.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settings;

  /// No description provided for @logout.
  ///
  /// In en, this message translates to:
  /// **'Logout'**
  String get logout;

  /// No description provided for @language.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get language;

  /// No description provided for @energy.
  ///
  /// In en, this message translates to:
  /// **'Energy'**
  String get energy;

  /// No description provided for @currentPower.
  ///
  /// In en, this message translates to:
  /// **'Current Power'**
  String get currentPower;

  /// No description provided for @cost.
  ///
  /// In en, this message translates to:
  /// **'Cost'**
  String get cost;

  /// No description provided for @noDevices.
  ///
  /// In en, this message translates to:
  /// **'No devices yet'**
  String get noDevices;

  /// No description provided for @addFirstDevice.
  ///
  /// In en, this message translates to:
  /// **'Add your first SHE device to get started'**
  String get addFirstDevice;

  /// No description provided for @provisioning.
  ///
  /// In en, this message translates to:
  /// **'Add Device'**
  String get provisioning;

  /// No description provided for @scanQrCode.
  ///
  /// In en, this message translates to:
  /// **'Scan the QR code on your device'**
  String get scanQrCode;

  /// No description provided for @macAddress.
  ///
  /// In en, this message translates to:
  /// **'MAC Address'**
  String get macAddress;

  /// No description provided for @pop.
  ///
  /// In en, this message translates to:
  /// **'PoP (9-digit)'**
  String get pop;

  /// No description provided for @wifiNetwork.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Network'**
  String get wifiNetwork;

  /// No description provided for @wifiPassword.
  ///
  /// In en, this message translates to:
  /// **'Wi-Fi Password'**
  String get wifiPassword;

  /// No description provided for @startProvisioning.
  ///
  /// In en, this message translates to:
  /// **'Start Provisioning'**
  String get startProvisioning;

  /// No description provided for @online.
  ///
  /// In en, this message translates to:
  /// **'Online'**
  String get online;

  /// No description provided for @offline.
  ///
  /// In en, this message translates to:
  /// **'Offline'**
  String get offline;

  /// No description provided for @device.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get device;

  /// No description provided for @error.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get error;

  /// No description provided for @members.
  ///
  /// In en, this message translates to:
  /// **'Members'**
  String get members;

  /// No description provided for @membersSubtitle.
  ///
  /// In en, this message translates to:
  /// **'People who can control this home'**
  String get membersSubtitle;

  /// No description provided for @noMembers.
  ///
  /// In en, this message translates to:
  /// **'No members yet'**
  String get noMembers;

  /// No description provided for @noMembersHint.
  ///
  /// In en, this message translates to:
  /// **'Invite someone by email to share control of this home.'**
  String get noMembersHint;

  /// No description provided for @addMember.
  ///
  /// In en, this message translates to:
  /// **'Add Member'**
  String get addMember;

  /// No description provided for @memberEmailHint.
  ///
  /// In en, this message translates to:
  /// **'member@example.com'**
  String get memberEmailHint;

  /// No description provided for @role.
  ///
  /// In en, this message translates to:
  /// **'Role'**
  String get role;

  /// No description provided for @remove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get remove;

  /// No description provided for @cancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get cancel;

  /// No description provided for @save.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get save;

  /// Title of the confirm dialog when removing a home member
  ///
  /// In en, this message translates to:
  /// **'Remove member'**
  String get removeMemberTitle;

  /// Confirmation body when removing a home member
  ///
  /// In en, this message translates to:
  /// **'Remove {email} from this home?'**
  String removeMemberConfirm(String email);

  /// No description provided for @roleOwner.
  ///
  /// In en, this message translates to:
  /// **'Owner'**
  String get roleOwner;

  /// No description provided for @roleAdmin.
  ///
  /// In en, this message translates to:
  /// **'Admin'**
  String get roleAdmin;

  /// No description provided for @roleMember.
  ///
  /// In en, this message translates to:
  /// **'Member'**
  String get roleMember;

  /// No description provided for @roleGuest.
  ///
  /// In en, this message translates to:
  /// **'Guest'**
  String get roleGuest;

  /// No description provided for @memberAdded.
  ///
  /// In en, this message translates to:
  /// **'{email} added'**
  String memberAdded(String email);

  /// No description provided for @memberRemoved.
  ///
  /// In en, this message translates to:
  /// **'Member removed'**
  String get memberRemoved;

  /// No description provided for @memberRoleUpdated.
  ///
  /// In en, this message translates to:
  /// **'Role updated'**
  String get memberRoleUpdated;

  /// No description provided for @emailRequired.
  ///
  /// In en, this message translates to:
  /// **'Email is required'**
  String get emailRequired;

  /// No description provided for @emailInvalid.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get emailInvalid;

  /// No description provided for @telemetry.
  ///
  /// In en, this message translates to:
  /// **'Telemetry'**
  String get telemetry;

  /// No description provided for @refresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get refresh;

  /// No description provided for @latestReadings.
  ///
  /// In en, this message translates to:
  /// **'Latest readings'**
  String get latestReadings;

  /// No description provided for @samples.
  ///
  /// In en, this message translates to:
  /// **'samples'**
  String get samples;

  /// No description provided for @trend.
  ///
  /// In en, this message translates to:
  /// **'Trend'**
  String get trend;

  /// No description provided for @needMoreSamples.
  ///
  /// In en, this message translates to:
  /// **'Need at least two samples to draw a trend.'**
  String get needMoreSamples;

  /// No description provided for @noTelemetryYet.
  ///
  /// In en, this message translates to:
  /// **'No telemetry recorded for this node yet.'**
  String get noTelemetryYet;

  /// No description provided for @upgradeToPremium.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Premium'**
  String get upgradeToPremium;

  /// No description provided for @upgradeToFamily.
  ///
  /// In en, this message translates to:
  /// **'Upgrade to Family'**
  String get upgradeToFamily;

  /// No description provided for @b2cPremium.
  ///
  /// In en, this message translates to:
  /// **'Premium'**
  String get b2cPremium;

  /// No description provided for @b2cFamily.
  ///
  /// In en, this message translates to:
  /// **'Family'**
  String get b2cFamily;

  /// No description provided for @b2cFree.
  ///
  /// In en, this message translates to:
  /// **'Free'**
  String get b2cFree;

  /// No description provided for @payViaTelebirr.
  ///
  /// In en, this message translates to:
  /// **'Pay via Telebirr'**
  String get payViaTelebirr;

  /// No description provided for @acceptedPaymentMethods.
  ///
  /// In en, this message translates to:
  /// **'Accepted: Telebirr, CBE Birr, Cards'**
  String get acceptedPaymentMethods;

  /// No description provided for @unlimitedDevices.
  ///
  /// In en, this message translates to:
  /// **'Unlimited devices'**
  String get unlimitedDevices;

  /// No description provided for @automationsAndScenes.
  ///
  /// In en, this message translates to:
  /// **'Automations + scenes'**
  String get automationsAndScenes;

  /// No description provided for @otaUpdates.
  ///
  /// In en, this message translates to:
  /// **'OTA updates'**
  String get otaUpdates;

  /// No description provided for @energyMonitoring.
  ///
  /// In en, this message translates to:
  /// **'Energy monitoring'**
  String get energyMonitoring;

  /// No description provided for @anomalyAlerts.
  ///
  /// In en, this message translates to:
  /// **'Anomaly alerts'**
  String get anomalyAlerts;

  /// No description provided for @fiveMembersShared.
  ///
  /// In en, this message translates to:
  /// **'5 members + shared homes'**
  String get fiveMembersShared;

  /// No description provided for @prioritySupport.
  ///
  /// In en, this message translates to:
  /// **'Priority support'**
  String get prioritySupport;

  /// No description provided for @energyMonitoringNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Energy monitoring is available on SHE-R8 and SHE-R16. Your SHE-R4 device does not have a power sensor.'**
  String get energyMonitoringNotAvailable;

  /// No description provided for @todaySummary.
  ///
  /// In en, this message translates to:
  /// **'Today\'s Summary'**
  String get todaySummary;

  /// No description provided for @sevenDayHistory.
  ///
  /// In en, this message translates to:
  /// **'7-Day History'**
  String get sevenDayHistory;

  /// No description provided for @fourteenDayHistory.
  ///
  /// In en, this message translates to:
  /// **'14-Day History'**
  String get fourteenDayHistory;

  /// No description provided for @thirtyDayHistory.
  ///
  /// In en, this message translates to:
  /// **'30-Day History'**
  String get thirtyDayHistory;

  /// No description provided for @anomalyDetection.
  ///
  /// In en, this message translates to:
  /// **'Anomaly Detection'**
  String get anomalyDetection;

  /// No description provided for @monthlyProjection.
  ///
  /// In en, this message translates to:
  /// **'Monthly Projection'**
  String get monthlyProjection;

  /// No description provided for @atCurrentRate.
  ///
  /// In en, this message translates to:
  /// **'At current rate, you\'ll use'**
  String get atCurrentRate;

  /// No description provided for @thisMonth.
  ///
  /// In en, this message translates to:
  /// **'this month'**
  String get thisMonth;

  /// No description provided for @powerSpikeDetected.
  ///
  /// In en, this message translates to:
  /// **'Power spike detected'**
  String get powerSpikeDetected;

  /// No description provided for @powerConsumptionHigh.
  ///
  /// In en, this message translates to:
  /// **'Your power consumption is 3× higher than usual'**
  String get powerConsumptionHigh;

  /// No description provided for @scenesRowTitle.
  ///
  /// In en, this message translates to:
  /// **'Scenes'**
  String get scenesRowTitle;

  /// No description provided for @goodMorning.
  ///
  /// In en, this message translates to:
  /// **'Good Morning'**
  String get goodMorning;

  /// No description provided for @leavingHome.
  ///
  /// In en, this message translates to:
  /// **'Leaving Home'**
  String get leavingHome;

  /// No description provided for @movieNight.
  ///
  /// In en, this message translates to:
  /// **'Movie Night'**
  String get movieNight;

  /// No description provided for @sleepMode.
  ///
  /// In en, this message translates to:
  /// **'Sleep Mode'**
  String get sleepMode;

  /// No description provided for @voiceControl.
  ///
  /// In en, this message translates to:
  /// **'Voice Control'**
  String get voiceControl;

  /// No description provided for @heySheba.
  ///
  /// In en, this message translates to:
  /// **'Hey Sheba'**
  String get heySheba;

  /// No description provided for @voiceListening.
  ///
  /// In en, this message translates to:
  /// **'Listening...'**
  String get voiceListening;

  /// No description provided for @voiceProcessing.
  ///
  /// In en, this message translates to:
  /// **'Processing...'**
  String get voiceProcessing;

  /// No description provided for @voiceLastIntent.
  ///
  /// In en, this message translates to:
  /// **'Last Command'**
  String get voiceLastIntent;

  /// No description provided for @voiceConfidence.
  ///
  /// In en, this message translates to:
  /// **'Confidence'**
  String get voiceConfidence;

  /// No description provided for @voiceNotAvailable.
  ///
  /// In en, this message translates to:
  /// **'Voice control is available on SHE-R16 only'**
  String get voiceNotAvailable;

  /// No description provided for @selectTheme.
  ///
  /// In en, this message translates to:
  /// **'Theme'**
  String get selectTheme;

  /// No description provided for @darkMode.
  ///
  /// In en, this message translates to:
  /// **'Dark Mode'**
  String get darkMode;

  /// No description provided for @lightMode.
  ///
  /// In en, this message translates to:
  /// **'Light Mode'**
  String get lightMode;

  /// No description provided for @systemTheme.
  ///
  /// In en, this message translates to:
  /// **'System'**
  String get systemTheme;

  /// No description provided for @useEthiopianCalendar.
  ///
  /// In en, this message translates to:
  /// **'Use Ethiopian Calendar'**
  String get useEthiopianCalendar;

  /// No description provided for @twoFactorAuth.
  ///
  /// In en, this message translates to:
  /// **'Two-Factor Authentication'**
  String get twoFactorAuth;

  /// No description provided for @mfaComingSoon.
  ///
  /// In en, this message translates to:
  /// **'Enable MFA (coming in Phase 5B)'**
  String get mfaComingSoon;

  /// No description provided for @selectLanguage.
  ///
  /// In en, this message translates to:
  /// **'Select Language'**
  String get selectLanguage;

  /// No description provided for @amharic.
  ///
  /// In en, this message translates to:
  /// **'አማርኛ (Amharic)'**
  String get amharic;

  /// No description provided for @english.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get english;

  /// No description provided for @retry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get retry;

  /// No description provided for @failedToLoadDevices.
  ///
  /// In en, this message translates to:
  /// **'Failed to load devices'**
  String get failedToLoadDevices;

  /// No description provided for @cannotDeleteOwnAccount.
  ///
  /// In en, this message translates to:
  /// **'Cannot delete your own account'**
  String get cannotDeleteOwnAccount;

  /// No description provided for @weakPassword.
  ///
  /// In en, this message translates to:
  /// **'Password must be at least 12 characters with 1 uppercase, 1 lowercase, 1 digit, 1 special character'**
  String get weakPassword;

  /// No description provided for @invalidEmail.
  ///
  /// In en, this message translates to:
  /// **'Invalid email address'**
  String get invalidEmail;

  /// No description provided for @invalidPhone.
  ///
  /// In en, this message translates to:
  /// **'Ethiopian phone format: +2519XXXXXXXX or 09XXXXXXXX'**
  String get invalidPhone;

  /// No description provided for @donatedHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? Login'**
  String get donatedHaveAccount;

  /// No description provided for @noAccountRegister.
  ///
  /// In en, this message translates to:
  /// **'Don\'t have an account? Register'**
  String get noAccountRegister;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['am', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'am':
      return AppLocalizationsAm();
    case 'en':
      return AppLocalizationsEn();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
