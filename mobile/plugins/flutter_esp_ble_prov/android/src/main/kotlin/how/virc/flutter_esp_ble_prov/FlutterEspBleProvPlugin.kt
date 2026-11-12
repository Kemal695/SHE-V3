package how.virc.flutter_esp_ble_prov

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.BluetoothDevice
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import com.espressif.provisioning.*
import com.espressif.provisioning.listeners.BleScanListener
import com.espressif.provisioning.listeners.ProvisionListener
import com.espressif.provisioning.listeners.ResponseListener
import com.espressif.provisioning.listeners.WiFiScanListener
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import org.greenrobot.eventbus.EventBus
import org.greenrobot.eventbus.Subscribe
import org.greenrobot.eventbus.ThreadMode
import java.util.concurrent.atomic.AtomicBoolean


/**
 * The data required to be able to connect to an Espressif BLE device.
 *
 * @param device The BLE device from a BLE scan
 * @param scanResult The ScanResult from a BLE scan
 */
class BleConnector(val device: BluetoothDevice, scanResult: ScanResult) {

  /**
   * The service ID used when connecting
   */
  val primaryServiceUuid: String

  init {
    primaryServiceUuid = scanResult.scanRecord?.serviceUuids?.get(0)?.toString() ?: ""
  }
}


/**
 * Combined context from a method channel call from the Flutter side.
 */
class CallContext(val call: MethodCall, val result: Result) {

  /**
   * Extracts an argument's value from the method call, and returns an error condition if it is not
   * present.
   */
  fun arg(name: String): String? {
    val v = call.argument<String>(name)
    if (v == null) {
      result.error("E0", "Missing argument: $name", "The argument $name was not provided")
    }
    return v
  }

}


/**
 * Allows for asynchronously requesting permissions based on platform version.
 *
 * The version switch is required because Bluetooth permission requirements changed at S (31).
 */
class PermissionManager(val boss: Boss) : PluginRegistry.RequestPermissionsResultListener {

  lateinit var callback: (Boolean) -> Unit

  val callbacks = mutableMapOf<Int, (Boolean) -> Unit>()
  var lastCallbackId = 0

  /**
   * Required permissions for the current version of the SDK.
   */
  val permissions: Array<String>
    get() {
      // https://developer.android.com/guide/topics/connectivity/bluetooth/permissions
      return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
      } else {
        arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.BLUETOOTH, Manifest.permission.BLUETOOTH_ADMIN)
      }
    }

  /**
   * Check permissions are granted and request them otherwise.
   */
  fun ensure(fCallback: (Boolean) -> Unit) {
    callback = fCallback
    val toRequest: MutableList<String> = mutableListOf()
    for (p in permissions) {
      if (ActivityCompat.checkSelfPermission(boss.platformActivity, p) != PackageManager.PERMISSION_GRANTED) {
        toRequest.add(p)
      }
    }
    if (toRequest.size > 0) {
      ActivityCompat.requestPermissions(boss.platformActivity, toRequest.toTypedArray(), 0)
    } else {
      fCallback(true)
    }
  }

  /**
   * Called on permission request result.
   */
  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
    boss.d("permission result")
    if (this::callback.isInitialized) {
      callback(true)
    }
    return true
  }
}


abstract class ActionManager(val boss: Boss) {
  abstract fun call(ctx: CallContext)
}


/**
 * Overall controller for method handling and state.
 *
 * Everything is asynchronous here, and this class handles that stuff through a series of
 * "manager" classes.
 */
class Boss {

  private val logTag = "FlutterEspBleProv"

  /** Android BLE service discovery is flaky; give it a few tries before reporting failure. */
  private val MAX_CONNECT_ATTEMPTS = 3
  private val RETRY_DELAY_MS = 900L
  private val CONNECT_TIMEOUT_MS = 15000L

  // Method names as called from Flutter across the channel.
  private val scanBleMethod = "scanBleDevices"
  private val scanWifiMethod = "scanWifiNetworks"
  private val provisionWifiMethod = "provisionWifi"
  private val provisionCustomDataMethod = "provisionCustomData"
  private val platformVersionMethod = "getPlatformVersion"

  /**
   * The available scanned BLE devices.
   */
  val devices = mutableMapOf<String, BleConnector>()

  /**
   * The available WiFi networks for the most recently scanned BLE device.
   */
  val networks = mutableSetOf<String>()

  // Managers performing the various actions
  private val permissionManager: PermissionManager = PermissionManager(this)
  private val bleScanner: BleScanManager = BleScanManager(this)
  private val wifiScanner: WifiScanManager = WifiScanManager(this)
  private val wifiProvisioner: WifiProvisionManager = WifiProvisionManager(this)
  private val customDataProvisioner: CustomDataProvisionManager = CustomDataProvisionManager(this)

  private lateinit var platformContext: Context
  lateinit var platformActivity: Activity

  val espManager: ESPProvisionManager get() = ESPProvisionManager.getInstance(platformContext)

  // Logging shortcuts
  fun d(msg: String) = Log.d(logTag, msg)
  fun e(msg: String) = Log.e(logTag, msg)
  fun i(msg: String) = Log.i(logTag, msg)

  fun connector(deviceName: String): BleConnector? {
    return devices[deviceName]
  }

  /**
   * Connect to a named device with proofOfPossession string, and once connected, execute the
   * callback.
   *
   * The Espressif library reports a failed GATT connection / service discovery through
   * DeviceConnectionEvent(EVENT_DEVICE_CONNECTION_FAILED) and otherwise stays silent, so a
   * failed connect used to leave the Flutter call hanging forever. Failures (and a timeout, in
   * case the library reports nothing at all) now come back through onFailureCallback.
   *
   * Retries: the library posts EVENT_DEVICE_CONNECTION_FAILED for BOTH a non-success
   * service-discovery status (the well-known transient Android GATT 133/129 error) and a
   * genuine "service UUID is not in the discovered list". Android's discovery step fails
   * intermittently even against a perfectly healthy peripheral and the next attempt usually
   * succeeds, so retry before surfacing an error — a single transient glitch used to abort the
   * whole provisioning flow.
   */
  fun connect(
    conn: BleConnector,
    proofOfPossession: String,
    onConnectCallback: (ESPDevice) -> Unit,
    onFailureCallback: (String) -> Unit,
  ) {
    connectAttempt(conn, proofOfPossession, 1, onConnectCallback, onFailureCallback)
  }

  private fun connectAttempt(
    conn: BleConnector,
    proofOfPossession: String,
    attempt: Int,
    onConnectCallback: (ESPDevice) -> Unit,
    onFailureCallback: (String) -> Unit,
  ) {
    val esp = espManager.createESPDevice(ESPConstants.TransportType.TRANSPORT_BLE, ESPConstants.SecurityType.SECURITY_1)
    // Both EventBus (ThreadMode.MAIN) and the Handler below run on the main thread, so a plain
    // flag is enough to keep the callbacks exclusive.
    var settled = false
    val mainHandler = Handler(Looper.getMainLooper())

    fun retryOrFail(reason: String) {
      try {
        esp.disconnectDevice()
      } catch (e: Exception) {
        d("disconnect after failure failed: $e")
      }
      if (attempt < MAX_CONNECT_ATTEMPTS) {
        d("connect attempt $attempt failed ($reason) — retrying")
        mainHandler.postDelayed({
          connectAttempt(conn, proofOfPossession, attempt + 1, onConnectCallback, onFailureCallback)
        }, RETRY_DELAY_MS)
      } else {
        onFailureCallback(
          "GATT connect failed for ${conn.device.name} after $attempt attempts: provisioning " +
            "service ${conn.primaryServiceUuid} not found (or its characteristics could not be " +
            "read). Check that the firmware advertises the expected service UUID."
        )
      }
    }

    val subscriber = object {
      @Subscribe(threadMode = ThreadMode.MAIN)
      fun onEvent(event: DeviceConnectionEvent) {
        d("bus event $event ${event.eventType} (attempt $attempt)")
        when (event.eventType) {
          ESPConstants.EVENT_DEVICE_CONNECTED -> {
            if (settled) return
            settled = true
            mainHandler.removeCallbacksAndMessages(null)
            EventBus.getDefault().unregister(this)
            esp.proofOfPossession = proofOfPossession
            onConnectCallback(esp)
          }
          ESPConstants.EVENT_DEVICE_CONNECTION_FAILED -> {
            if (settled) return
            settled = true
            mainHandler.removeCallbacksAndMessages(null)
            EventBus.getDefault().unregister(this)
            retryOrFail("connection failed")
          }
        }
      }
    }
    EventBus.getDefault().register(subscriber)
    mainHandler.postDelayed({
      if (!settled) {
        settled = true
        EventBus.getDefault().unregister(subscriber)
        d("esp connect: timed out (attempt $attempt)")
        retryOrFail("timed out after ${CONNECT_TIMEOUT_MS / 1000}s")
      }
    }, CONNECT_TIMEOUT_MS)
    esp.connectBLEDevice(conn.device, conn.primaryServiceUuid)
  }

  fun call(call: MethodCall, result: Result) {
    permissionManager.ensure(fun(_: Boolean) {
      val ctx = CallContext(call, result)
      when (call.method) {
        platformVersionMethod -> getPlatformVersion(ctx)
        scanBleMethod -> bleScanner.call(ctx)
        scanWifiMethod -> wifiScanner.call(ctx)
        provisionWifiMethod -> wifiProvisioner.call(ctx)
        provisionCustomDataMethod -> customDataProvisioner.call(ctx)
        else -> result.notImplemented()
      }
    })
  }

  private fun getPlatformVersion(ctx: CallContext) {
    ctx.result.success("Android ${Build.VERSION.RELEASE}")
  }

  fun attachActivity(activity: Activity) {
    platformActivity = activity
  }

  fun attachContext(context: Context) {
    platformContext = context
  }

  fun attachBinding(binding: ActivityPluginBinding) {
    binding.addRequestPermissionsResultListener(permissionManager)
  }

  fun detachBinding(binding: ActivityPluginBinding) {
    binding.removeRequestPermissionsResultListener(permissionManager)
  }
}


class BleScanManager(boss: Boss) : ActionManager(boss) {

  @SuppressLint("MissingPermission")
  override fun call(ctx: CallContext) {
    boss.d("searchBleEspDevices: start")
    // Drop stale results so a re-scan never shows ghost entries from a
    // previous attempt (tapping a ghost fails with "Failed to create session").
    boss.devices.clear()
    boss.networks.clear()
    val prefix = ctx.arg("prefix") ?: return

    // The Espressif library can report more than one outcome for the same scan, and its
    // callbacks arrive on a library thread. `ctx.result` may only be completed once, so the
    // first outcome wins. These callbacks used to be `TODO("Not yet implemented")`, which
    // throws `NotImplementedError` — an uncaught throwable on a native callback thread, i.e.
    // an immediate process crash the moment a scan failed (Bluetooth off, permission denied,
    // adapter busy). That is the "app crashes on the provisioning screen" bug.
    val settled = AtomicBoolean(false)

    val fail: (String, String, String?) -> Unit = { code, message, detail ->
      if (settled.compareAndSet(false, true)) {
        boss.e("searchBleEspDevices: $message ($detail)")
        Handler(Looper.getMainLooper()).post { ctx.result.error(code, message, detail) }
      }
    }

    boss.espManager.searchBleEspDevices(prefix, object : BleScanListener {
      override fun scanStartFailed() {
        fail(
          "E3",
          "Bluetooth scan could not start",
          "Make sure Bluetooth is switched on and that the Nearby devices permission is granted."
        )
      }

      override fun onPeripheralFound(device: BluetoothDevice?, scanResult: ScanResult?) {
        device ?: return
        scanResult ?: return
        // A device that advertises no name cannot be provisioned later (the plugin looks the
        // device up by name), and a null map key would reach Dart as a null element inside a
        // List<String> — which throws a TypeError in `raw.cast<String>()`.
        val name = device.name ?: return
        boss.devices[name] = BleConnector(device, scanResult)
      }

      override fun scanCompleted() {
        if (!settled.compareAndSet(false, true)) return
        val names = ArrayList<String>(boss.devices.keys)
        boss.d("searchBleEspDevices: scanComplete $names")
        Handler(Looper.getMainLooper()).post { ctx.result.success(names) }
      }

      override fun onFailure(e: java.lang.Exception?) {
        fail("E3", "Bluetooth scan failed", e?.toString())
      }

    })
  }

}

class WifiScanManager(boss: Boss) : ActionManager(boss) {
  override fun call(ctx: CallContext) {
    val name = ctx.arg("deviceName") ?: return
    val proofOfPossession = ctx.arg("proofOfPossession") ?: return
    val conn = boss.connector(name) ?: return
    boss.d("esp connect: start")
    boss.connect(
      conn,
      proofOfPossession,
      onConnectCallback = { esp ->
        // Establish the protocomm security session explicitly instead of letting
        // ESPDevice.scanNetworks() do it internally: the library's own listener replaces every
        // failure cause with a generic "Failed to create session." exception (the real cause is
        // only printStackTrace()'d), which makes a wrong PoP indistinguishable from a missing
        // characteristic. Calling it here gives us the actual exception message.
        boss.d("session: start")
        esp.initSession(object : ResponseListener {
          override fun onSuccess(response: ByteArray?) {
            boss.d("session: established")
            scanNetworks(ctx, esp)
          }

          override fun onFailure(e: java.lang.Exception?) {
            boss.e("session: failed $e")
            // Surface what the library actually discovered. Logged at ERROR level
            // (and with a full stack trace) because release builds routinely drop
            // Log.d, which otherwise leaves "Session could not be established"
            // with no clue as to whether the endpoint map, the MTU or the
            // handshake was at fault.
            val caps = try {
              esp.deviceCapabilities?.toString()
            } catch (t: Throwable) {
              "unavailable: $t"
            }
            val ver = try {
              esp.versionInfo
            } catch (t: Throwable) {
              "unavailable: $t"
            }
            boss.e("session: DIAG versionInfo=$ver deviceCapabilities=$caps")
            e?.printStackTrace()
            val detail = "${e?.javaClass?.name}: ${e?.message ?: "(no message)"}"
            Handler(Looper.getMainLooper()).post {
              ctx.result.error(
                "E1",
                "Secure session rejected by $name",
                "PoP sent: ${proofOfPossession.length} chars; cause: $detail"
              )
            }
          }
        })
      },
      onFailureCallback = { msg ->
        boss.e("esp connect: failed $msg")
        Handler(Looper.getMainLooper()).post { ctx.result.error("E2", msg, null) }
      },
    )
  }

  private fun scanNetworks(ctx: CallContext, esp: ESPDevice) {
    boss.d("scanNetworks: start")
    esp.scanNetworks(object : WiFiScanListener {
      override fun onWifiListReceived(wifiList: ArrayList<WiFiAccessPoint>?) {
        wifiList ?: return
        wifiList.forEach { boss.networks.add(it.wifiName) }
        boss.d("scanNetworks: complete ${boss.networks}")
        Handler(Looper.getMainLooper()).post {
          ctx.result.success(ArrayList<String>(boss.networks))
        }
        boss.d("scanNetworks: complete 2 ${boss.networks}")
        esp.disconnectDevice()
      }

      override fun onWiFiScanFailed(e: java.lang.Exception?) {
        boss.e("scanNetworks: error $e")
        Handler(Looper.getMainLooper()).post {
          ctx.result.error("E1", "WiFi scan failed", "Exception details $e")
        }
      }
    })
  }
}


class WifiProvisionManager(boss: Boss) : ActionManager(boss) {
  override fun call(ctx: CallContext) {
    // NOTE: never log ctx.call.arguments here — it contains the Wi-Fi
    // passphrase in plaintext and logcat is world-readable to any app with
    // READ_LOGS. Log the SSID only.
    boss.e("provisionWifi ssid=${ctx.call.argument<String>("ssid")} " +
      "deviceName=${ctx.call.argument<String>("deviceName")}")
    val ssid = ctx.arg("ssid") ?: return
    val passphrase = ctx.arg("passphrase") ?: return
    val deviceName = ctx.arg("deviceName") ?: return
    val proofOfPossession = ctx.arg("proofOfPossession") ?: return
    val conn = boss.connector(deviceName) ?: return

    boss.connect(
      conn,
      proofOfPossession,
      onConnectCallback = { esp ->
        boss.d("provision: start")
        // The SHE firmware sets its `provisioned` flag and then REBOOTS ~2s after
        // getting an IP (ble_provisioning.c prov_event_handler -> esp_restart()).
        // That tears down the BLE link before the library can poll the final
        // status, so the library reports failure for what is actually a success.
        // Track whether the device already acknowledged applying the config.
        var configApplied = false
        esp.provision(ssid, passphrase, object : ProvisionListener {
        override fun createSessionFailed(e: java.lang.Exception?) {
          boss.e("wifiprovision createSessionFailed $e")
          // Previously this only logged and the Flutter call never completed, so the app sat
          // on its spinner forever after a rejected handshake.
          Handler(Looper.getMainLooper()).post {
            ctx.result.error(
              "E1",
              "Secure session rejected by $deviceName",
              "PoP sent: ${proofOfPossession.length} chars; cause: $e"
            )
          }
        }

        override fun wifiConfigSent() {
          boss.d("wifiConfigSent")
        }

        override fun wifiConfigFailed(e: java.lang.Exception?) {
          // Keep the exception: it is the only clue as to why the device
          // refused the credentials.
          boss.e("wifiConfigFailed $e")
          Handler(Looper.getMainLooper()).post {
            ctx.result.error("E1", "Device rejected Wi-Fi credentials", "$e")
          }
        }

        override fun wifiConfigApplied() {
          configApplied = true
          boss.d("wifiConfigApplied")
        }

        override fun wifiConfigApplyFailed(e: java.lang.Exception?) {
          boss.e("wifiConfigApplyFailed $e")
          Handler(Looper.getMainLooper()).post {
            ctx.result.error("E1", "Device could not apply Wi-Fi config", "$e")
          }
        }

        override fun provisioningFailedFromDevice(failureReason: ESPConstants.ProvisionFailureReason?) {
          // AUTH_FAILED / NETWORK_NOT_FOUND / DEVICE_DISCONNECTED / UNKNOWN —
          // this is THE answer for a failed Wi-Fi join, so surface it verbatim.
          boss.e("provisioningFailedFromDevice reason=$failureReason")
          Handler(Looper.getMainLooper()).post {
            ctx.result.error(
              "E1",
              "Device failed to join \"$ssid\" ($failureReason)",
              "reason=$failureReason"
            )
          }
        }

        override fun deviceProvisioningSuccess() {
          boss.d("deviceProvisioningSuccess")
          ctx.result.success(true)
        }

        override fun onProvisioningFailed(e: java.lang.Exception?) {
          // Was logged WITHOUT the exception, which threw away the only
          // diagnostic the library gives us here.
          boss.e("onProvisioningFailed $e (configApplied=$configApplied)")
          if (configApplied) {
            // The device acknowledged the credentials and then vanished — that is
            // the firmware rebooting to join the network, not a failure.
            boss.e("onProvisioningFailed after wifiConfigApplied -> treating as SUCCESS")
            Handler(Looper.getMainLooper()).post { ctx.result.success(true) }
          } else {
            Handler(Looper.getMainLooper()).post {
              ctx.result.error("E1", "Provisioning failed for \"$ssid\"", "$e")
            }
          }
        }

        })
      },
      onFailureCallback = { msg ->
        boss.e("esp connect: failed $msg")
        Handler(Looper.getMainLooper()).post { ctx.result.error("E2", msg, null) }
      },
    )
  }

}

/**
 * Sends a JSON payload to a CUSTOM provisioning endpoint on the device.
 *
 * SHE uses this to hand the device its server address (broker + API base), so a
 * single provisioning pass writes the complete connectivity config. Without it
 * the device only learns where the NETWORK is, and the broker stays at whatever
 * was baked in at manufacturing time — every server address change then leaves
 * the board joining Wi-Fi successfully and dialling a host that no longer
 * exists.
 *
 * MUST be called BEFORE provisionWifi: the firmware reboots a couple of seconds
 * after it obtains an IP, which tears down the BLE session and any chance of
 * sending this afterwards.
 */
class CustomDataProvisionManager(boss: Boss) : ActionManager(boss) {
  override fun call(ctx: CallContext) {
    // NOTE: never log ctx.call.arguments — it would dump the whole payload.
    val deviceName = ctx.arg("deviceName") ?: return
    val proofOfPossession = ctx.arg("proofOfPossession") ?: return
    val data = ctx.arg("data") ?: return
    val endpoint = ctx.arg("endpoint") ?: return
    boss.e("provisionCustomData device=$deviceName endpoint=$endpoint bytes=${data.length}")
    val conn = boss.connector(deviceName) ?: return

    boss.connect(
      conn,
      proofOfPossession,
      onConnectCallback = { esp ->
        boss.d("customData: start")
        esp.provisionCustomData(data, endpoint, object : ProvisionListener {
          override fun createSessionFailed(e: java.lang.Exception?) {
            boss.e("customData createSessionFailed $e")
            Handler(Looper.getMainLooper()).post {
              ctx.result.error("E1", "Secure session rejected by $deviceName", "$e")
            }
          }

          override fun wifiConfigSent() {
            boss.d("customData wifiConfigSent")
          }

          override fun wifiConfigFailed(e: java.lang.Exception?) {
            boss.e("customData wifiConfigFailed $e")
          }

          override fun wifiConfigApplied() {
            boss.d("customData wifiConfigApplied")
          }

          override fun wifiConfigApplyFailed(e: java.lang.Exception?) {
            boss.e("customData wifiConfigApplyFailed $e")
          }

          override fun provisioningFailedFromDevice(failureReason: ESPConstants.ProvisionFailureReason?) {
            boss.e("customData failedFromDevice reason=$failureReason")
            Handler(Looper.getMainLooper()).post {
              ctx.result.error(
                "E1",
                "Device rejected endpoint \"$endpoint\" ($failureReason)",
                "reason=$failureReason"
              )
            }
          }

          override fun deviceProvisioningSuccess() {
            boss.d("customData success")
            // Free the BLE link: provisionWifi() opens its own connection next,
            // and this device reboots on its own schedule, not ours.
            try {
              esp.disconnectDevice()
            } catch (e: Exception) {
              boss.e("customData disconnect failed: $e")
            }
            Handler(Looper.getMainLooper()).post { ctx.result.success(true) }
          }

          override fun onProvisioningFailed(e: java.lang.Exception?) {
            boss.e("customData onProvisioningFailed $e")
            Handler(Looper.getMainLooper()).post {
              ctx.result.error("E1", "Custom data not delivered", "$e")
            }
          }
        })
      },
      onFailureCallback = { msg ->
        boss.e("esp connect: failed $msg")
        Handler(Looper.getMainLooper()).post { ctx.result.error("E2", msg, null) }
      },
    )
  }
}


/** FlutterEspBleProvPlugin */
class FlutterEspBleProvPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.ActivityResultListener {

  private val logTag = "FlutterEspBleProvChannel"
  private val boss = Boss()
  private lateinit var channel: MethodChannel
  private var activityBinding: ActivityPluginBinding? = null

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(logTag, "onAttachedToEngine: $binding")
    channel = MethodChannel(binding.binaryMessenger, "flutter_esp_ble_prov")
    channel.setMethodCallHandler(this)
    boss.attachContext(binding.applicationContext)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    Log.d(logTag, "onDetachedFromEngine: $binding")
    channel.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: Result) {
    Log.d(logTag, "onMethodCall: ${call.method} ${call.arguments}")
    boss.call(call, result)
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    Log.d(logTag, "onAttachedToActivity: $binding")
    init(binding)
  }

  override fun onDetachedFromActivityForConfigChanges() {
    Log.d(logTag, "onDetachedFromActivityForConfigChanges")
    activityBinding?.let { tearDown(it) }
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    Log.d(logTag, "onReattachedToActivityForConfigChanges: $binding")
    init(binding)
  }

  override fun onDetachedFromActivity() {
    Log.d(logTag, "onDetachedFromActivity")
    activityBinding?.let { tearDown(it) }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    Log.d(logTag, "onActivityResult $requestCode $resultCode $data")
    return false
  }

  private fun init(binding: ActivityPluginBinding) {
    activityBinding = binding;
    binding.addActivityResultListener(this)
    boss.attachBinding(binding)
    boss.attachActivity(binding.activity)
  }

  private fun tearDown(binding: ActivityPluginBinding) {
    binding.removeActivityResultListener(this)
    boss.detachBinding(binding)
    activityBinding = null;
  }
}
