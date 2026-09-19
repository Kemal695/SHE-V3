// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Smart Home Ethiopia';

  @override
  String get login => 'Login';

  @override
  String get register => 'Register';

  @override
  String get email => 'Email';

  @override
  String get password => 'Password';

  @override
  String get fullName => 'Full Name';

  @override
  String get phone => 'Phone';

  @override
  String get dashboard => 'My Home';

  @override
  String get addDevice => 'Add Device';

  @override
  String get settings => 'Settings';

  @override
  String get logout => 'Logout';

  @override
  String get language => 'Language';

  @override
  String get energy => 'Energy';

  @override
  String get currentPower => 'Current Power';

  @override
  String get cost => 'Cost';

  @override
  String get noDevices => 'No devices yet';

  @override
  String get addFirstDevice => 'Add your first SHE device to get started';

  @override
  String get provisioning => 'Add Device';

  @override
  String get scanQrCode => 'Scan the QR code on your device';

  @override
  String get macAddress => 'MAC Address';

  @override
  String get pop => 'PoP (9-digit)';

  @override
  String get wifiNetwork => 'Wi-Fi Network';

  @override
  String get wifiPassword => 'Wi-Fi Password';

  @override
  String get startProvisioning => 'Start Provisioning';

  @override
  String get online => 'Online';

  @override
  String get offline => 'Offline';

  @override
  String get device => 'Device';

  @override
  String get error => 'Error';

  @override
  String get members => 'Members';

  @override
  String get membersSubtitle => 'People who can control this home';

  @override
  String get noMembers => 'No members yet';

  @override
  String get noMembersHint =>
      'Invite someone by email to share control of this home.';

  @override
  String get addMember => 'Add Member';

  @override
  String get memberEmailHint => 'member@example.com';

  @override
  String get role => 'Role';

  @override
  String get remove => 'Remove';

  @override
  String get cancel => 'Cancel';

  @override
  String get save => 'Save';

  @override
  String get removeMemberTitle => 'Remove member';

  @override
  String removeMemberConfirm(String email) {
    return 'Remove $email from this home?';
  }

  @override
  String get roleOwner => 'Owner';

  @override
  String get roleAdmin => 'Admin';

  @override
  String get roleMember => 'Member';

  @override
  String get roleGuest => 'Guest';

  @override
  String memberAdded(String email) {
    return '$email added';
  }

  @override
  String get memberRemoved => 'Member removed';

  @override
  String get memberRoleUpdated => 'Role updated';

  @override
  String get emailRequired => 'Email is required';

  @override
  String get emailInvalid => 'Enter a valid email address';

  @override
  String get telemetry => 'Telemetry';

  @override
  String get refresh => 'Refresh';

  @override
  String get latestReadings => 'Latest readings';

  @override
  String get samples => 'samples';

  @override
  String get trend => 'Trend';

  @override
  String get needMoreSamples => 'Need at least two samples to draw a trend.';

  @override
  String get noTelemetryYet => 'No telemetry recorded for this node yet.';

  @override
  String get upgradeToPremium => 'Upgrade to Premium';

  @override
  String get upgradeToFamily => 'Upgrade to Family';

  @override
  String get b2cPremium => 'Premium';

  @override
  String get b2cFamily => 'Family';

  @override
  String get b2cFree => 'Free';

  @override
  String get payViaTelebirr => 'Pay via Telebirr';

  @override
  String get acceptedPaymentMethods => 'Accepted: Telebirr, CBE Birr, Cards';

  @override
  String get unlimitedDevices => 'Unlimited devices';

  @override
  String get automationsAndScenes => 'Automations + scenes';

  @override
  String get otaUpdates => 'OTA updates';

  @override
  String get energyMonitoring => 'Energy monitoring';

  @override
  String get anomalyAlerts => 'Anomaly alerts';

  @override
  String get fiveMembersShared => '5 members + shared homes';

  @override
  String get prioritySupport => 'Priority support';

  @override
  String get energyMonitoringNotAvailable =>
      'Energy monitoring is available on SHE-R8 and SHE-R16. Your SHE-R4 device does not have a power sensor.';

  @override
  String get todaySummary => 'Today\'s Summary';

  @override
  String get sevenDayHistory => '7-Day History';

  @override
  String get fourteenDayHistory => '14-Day History';

  @override
  String get thirtyDayHistory => '30-Day History';

  @override
  String get anomalyDetection => 'Anomaly Detection';

  @override
  String get monthlyProjection => 'Monthly Projection';

  @override
  String get atCurrentRate => 'At current rate, you\'ll use';

  @override
  String get thisMonth => 'this month';

  @override
  String get powerSpikeDetected => 'Power spike detected';

  @override
  String get powerConsumptionHigh =>
      'Your power consumption is 3× higher than usual';

  @override
  String get scenesRowTitle => 'Scenes';

  @override
  String get goodMorning => 'Good Morning';

  @override
  String get leavingHome => 'Leaving Home';

  @override
  String get movieNight => 'Movie Night';

  @override
  String get sleepMode => 'Sleep Mode';

  @override
  String get voiceControl => 'Voice Control';

  @override
  String get heySheba => 'Hey Sheba';

  @override
  String get voiceListening => 'Listening...';

  @override
  String get voiceProcessing => 'Processing...';

  @override
  String get voiceLastIntent => 'Last Command';

  @override
  String get voiceConfidence => 'Confidence';

  @override
  String get voiceNotAvailable => 'Voice control is available on SHE-R16 only';

  @override
  String get selectTheme => 'Theme';

  @override
  String get darkMode => 'Dark Mode';

  @override
  String get lightMode => 'Light Mode';

  @override
  String get systemTheme => 'System';

  @override
  String get useEthiopianCalendar => 'Use Ethiopian Calendar';

  @override
  String get twoFactorAuth => 'Two-Factor Authentication';

  @override
  String get mfaComingSoon => 'Enable MFA (coming in Phase 5B)';

  @override
  String get selectLanguage => 'Select Language';

  @override
  String get amharic => 'አማርኛ (Amharic)';

  @override
  String get english => 'English';

  @override
  String get retry => 'Retry';

  @override
  String get failedToLoadDevices => 'Failed to load devices';

  @override
  String get cannotDeleteOwnAccount => 'Cannot delete your own account';

  @override
  String get weakPassword =>
      'Password must be at least 12 characters with 1 uppercase, 1 lowercase, 1 digit, 1 special character';

  @override
  String get invalidEmail => 'Invalid email address';

  @override
  String get invalidPhone =>
      'Ethiopian phone format: +2519XXXXXXXX or 09XXXXXXXX';

  @override
  String get donatedHaveAccount => 'Already have an account? Login';

  @override
  String get noAccountRegister => 'Don\'t have an account? Register';
}
