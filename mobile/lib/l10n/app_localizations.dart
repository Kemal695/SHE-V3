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
