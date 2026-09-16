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
}
