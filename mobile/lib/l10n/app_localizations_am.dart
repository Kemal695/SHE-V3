// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Amharic (`am`).
class AppLocalizationsAm extends AppLocalizations {
  AppLocalizationsAm([String locale = 'am']) : super(locale);

  @override
  String get appTitle => 'ስማርት መኖር ኢትዮጵያ';

  @override
  String get login => 'ግባ';

  @override
  String get register => 'ተመዝገብ';

  @override
  String get email => 'ኢሜይል';

  @override
  String get password => 'የይለፍ ቃል';

  @override
  String get fullName => 'ሙሉ ስም';

  @override
  String get phone => 'ስልክ ቁጥር';

  @override
  String get dashboard => 'የእኔ ቤት';

  @override
  String get addDevice => 'መሣሪያ ጨምር';

  @override
  String get settings => 'ቅንብሮች';

  @override
  String get logout => 'ውጣ';

  @override
  String get language => 'ቋንቋ';

  @override
  String get energy => 'ኃይል';

  @override
  String get currentPower => 'አሁን ያለው ኃይል';

  @override
  String get cost => 'ወጪ';

  @override
  String get noDevices => 'እስካሁን ምንም መሣሪያ የለም';

  @override
  String get addFirstDevice => 'የመጀመሪያዎን SHE መሣሪያ ይጨምሩ';

  @override
  String get provisioning => 'መሣሪያ ጨምር';

  @override
  String get scanQrCode => 'በመሣሪያው ላይ ያለውን QR ኮድ ይቃኙ';

  @override
  String get macAddress => 'MAC አድራሻ';

  @override
  String get pop => 'PoP (9-አሃዝ)';

  @override
  String get wifiNetwork => 'የዋይፋይ ኔትወርክ';

  @override
  String get wifiPassword => 'የዋይፋይ የይለፍ ቃል';

  @override
  String get startProvisioning => 'ማዋቀር ይጀምሩ';

  @override
  String get online => 'መስመር ላይ';

  @override
  String get offline => 'መስመር ውጭ';

  @override
  String get device => 'መሣሪያ';

  @override
  String get error => 'ስህተት';

  @override
  String get members => 'አባላት';

  @override
  String get membersSubtitle => 'ይህንን ቤት መቆጣጠር የሚችሉ ሰዎች';

  @override
  String get noMembers => 'እስካሁን ምንም አባል የለም';

  @override
  String get noMembersHint => 'የዚህን ቤት ቁጥጥር ለማጋራት ሰው በኢሜይል ይጋብዙ።';

  @override
  String get addMember => 'አባል ጨምር';

  @override
  String get memberEmailHint => 'member@example.com';

  @override
  String get role => 'ሚና';

  @override
  String get remove => 'አስወግድ';

  @override
  String get cancel => 'ሰርዝ';

  @override
  String get save => 'አስቀምጥ';

  @override
  String get removeMemberTitle => 'አባል አስወግድ';

  @override
  String removeMemberConfirm(String email) {
    return '$email ከዚህ ቤት ይወገድ?';
  }

  @override
  String get roleOwner => 'ባለቤት';

  @override
  String get roleAdmin => 'አስተዳዳሪ';

  @override
  String get roleMember => 'አባል';

  @override
  String get roleGuest => 'እንግዳ';

  @override
  String memberAdded(String email) {
    return '$email ተጨምሯል';
  }

  @override
  String get memberRemoved => 'አባል ተወግዷል';

  @override
  String get memberRoleUpdated => 'ሚና ተዘምኗል';

  @override
  String get emailRequired => 'ኢሜይል ያስፈልጋል';

  @override
  String get emailInvalid => 'ትክክለኛ የኢሜይል አድራሻ ያስገቡ';

  @override
  String get telemetry => 'ቴሌሜትሪ';

  @override
  String get refresh => 'አድስ';

  @override
  String get latestReadings => 'የቅርብ ጊዜ ንባቦች';

  @override
  String get samples => 'ናሙናዎች';

  @override
  String get trend => 'አዝማሚያ';

  @override
  String get needMoreSamples => 'አዝማሚያ ለመሳል ቢያንስ ሁለት ናሙናዎች ያስፈልጋሉ።';

  @override
  String get noTelemetryYet => 'ለዚህ መሣሪያ እስካሁን ቴሌሜትሪ አልተመዘገበም።';

  @override
  String get upgradeToPremium => 'ወደ Premium ይለውጡ';

  @override
  String get upgradeToFamily => 'ወደ Family ይለውጡ';

  @override
  String get b2cPremium => 'Premium';

  @override
  String get b2cFamily => 'Family';

  @override
  String get b2cFree => 'ነፃ';

  @override
  String get payViaTelebirr => 'በቴሌብር ይክፈሉ';

  @override
  String get acceptedPaymentMethods => 'የተቀበሉ: ቴሌብር፣ በቢር፣ ካርዶች';

  @override
  String get unlimitedDevices => 'ወሰን አልባ መሣሪያዎች';

  @override
  String get automationsAndScenes => 'ራስ-ሰር ተግባሮች + ስኪኖች';

  @override
  String get otaUpdates => 'OTA ዝመናዎች';

  @override
  String get energyMonitoring => 'የኃይል መከታተል';

  @override
  String get anomalyAlerts => 'የአደጋ ማንቂያዎች';

  @override
  String get fiveMembersShared => '5 አባላት + የጋራ ቤቶች';

  @override
  String get prioritySupport => 'ቅድሚያ ድጋፍ';

  @override
  String get energyMonitoringNotAvailable =>
      'የኃይል መከታተል በ SHE-R8 እና SHE-R16 ላይ ይገኛል። የእርስዎ SHE-R4 መሣሪያ የኃይል ሰንሰር የለውም።';

  @override
  String get todaySummary => 'የዛሬ ማጠቃለያ';

  @override
  String get sevenDayHistory => '7-ቀን ታሪክ';

  @override
  String get fourteenDayHistory => '14-ቀን ታሪክ';

  @override
  String get thirtyDayHistory => '30-ቀን ታሪክ';

  @override
  String get anomalyDetection => 'የአደጋ ማሳወቂያ';

  @override
  String get monthlyProjection => 'ወርሃዊ ግምት';

  @override
  String get atCurrentRate => 'በአሁኑ ደረጃ እያገኙ ነው';

  @override
  String get thisMonth => 'በዚህ ወር';

  @override
  String get powerSpikeDetected => 'የኃይል መጠን መጨመር';

  @override
  String get powerConsumptionHigh => 'የእርስዎ የኃይል መጠን ከመደበኛው 3 እጥፍ ጨምሯል';

  @override
  String get scenesRowTitle => 'ስኪኖች';

  @override
  String get goodMorning => 'እንደምን አደሩ';

  @override
  String get leavingHome => 'ከቤት መውጣት';

  @override
  String get movieNight => 'የፊልም ምሽት';

  @override
  String get sleepMode => 'የእንቅልፍ ሁነታ';

  @override
  String get voiceControl => 'የድምፅ ቁጥጥር';

  @override
  String get heySheba => 'ሰበኣ';

  @override
  String get voiceListening => 'በማዳመጥ ላይ...';

  @override
  String get voiceProcessing => 'በማስኬድ ላይ...';

  @override
  String get voiceLastIntent => 'የመጨረሻ ትዕዛዝ';

  @override
  String get voiceConfidence => 'እምነት';

  @override
  String get voiceNotAvailable => 'የድምፅ ቁጥጥር በ SHE-R16 ላይ ብቻ ይገኛል';

  @override
  String get selectTheme => 'ጭብጥ';

  @override
  String get darkMode => 'ጨለማ ሁነታ';

  @override
  String get lightMode => 'ብርሃን ሁነታ';

  @override
  String get systemTheme => 'ሲስተም';

  @override
  String get useEthiopianCalendar => 'የኢትዮጵያ ቀን መቁጠሪያ ይጠቀሙ';

  @override
  String get twoFactorAuth => 'ሁለት-ደረጃ ማረጋገጫ';

  @override
  String get mfaComingSoon => 'MFA ያንቁ (በ Phase 5B ይመጣል)';

  @override
  String get selectLanguage => 'ቋንቋ ይምረጡ';

  @override
  String get amharic => 'አማርኛ (Amharic)';

  @override
  String get english => 'English';

  @override
  String get retry => 'እንደገና ይሞክሩ';

  @override
  String get failedToLoadDevices => 'መሣሪያዎችን መጫን አልተሳካም';

  @override
  String get cannotDeleteOwnAccount => 'የራስዎን መለያ መሰረዝ አይችሉም';

  @override
  String get weakPassword =>
      'የይለፍ ቃል ቢያንስ 12 ቁጥር መሆን አለበት ከእነዚህ ጋር: 1 በዓቢይ፣ 1 በአነስተኛ፣ 1 ቁጥር፣ 1 ልዩ ቁምፊ';

  @override
  String get invalidEmail => 'ዋጋ በማይገባ ኢሜይል';

  @override
  String get invalidPhone => 'የኢትዮጵያ ስልክ ቅርጸት: +2519XXXXXXXX ወይም 09XXXXXXXX';

  @override
  String get donatedHaveAccount => 'መለያ አለዎት? ግባ';

  @override
  String get noAccountRegister => 'መለያ የለዎትም? ተመዝገብ';
}
