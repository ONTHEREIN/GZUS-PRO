package com.tencent.reshub_flutter

import android.app.Application
import androidx.annotation.NonNull

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** ReshubFlutterPlugin */
class ReshubFlutterPlugin: FlutterPlugin, MethodCallHandler {
  /// The MethodChannel that will the communication between Flutter and native Android
  ///
  /// This local reference serves to register the plugin with the Flutter Engine and unregister it
  /// when the Flutter Engine is detached from the Activity
  private lateinit var channel : MethodChannel

  private lateinit var conchLoaderHostChannel: MethodChannel

  override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
    channel = MethodChannel(flutterPluginBinding.binaryMessenger, "reshub_flutter")
    channel.setMethodCallHandler(this)
    MsgProtocolGenerated.ReshubHostAction.setup(flutterPluginBinding.binaryMessenger, ReshubHostApiImpl)
    MsgProtocolGenerated.ReshubCenterHostAction.setup(flutterPluginBinding.binaryMessenger, ReshubHostApiImpl)
    ReshubHostApiImpl.initApplicationContext(flutterPluginBinding.applicationContext as Application)

    conchLoaderHostChannel = MethodChannel(flutterPluginBinding.binaryMessenger, "conch_loader_host")
    conchLoaderHostChannel.setMethodCallHandler(ConchLoaderHostImpl(flutterPluginBinding.applicationContext))
  }

  override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
    if (call.method == "getPlatformVersion") {
      result.success("Android ${android.os.Build.VERSION.RELEASE}")
    } else {
      result.notImplemented()
    }
  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    channel.setMethodCallHandler(null)
    conchLoaderHostChannel.setMethodCallHandler(null)
  }
}
