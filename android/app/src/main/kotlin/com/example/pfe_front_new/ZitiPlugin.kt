package com.example.pfe_front_new

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import org.openziti.Ziti
import org.openziti.ZitiContext
import org.openziti.ZitiException
import org.openziti.ZitiService
import java.io.File
import java.util.concurrent.CompletableFuture

class ZitiPlugin: FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var zitiContext: ZitiContext? = null
    private var currentService: ZitiService? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "com.example.pfe_front_new/ziti")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        disconnect()
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "initializeZiti" -> {
                val identityPath = call.argument<String>("identityPath")
                if (identityPath == null) {
                    result.error("INVALID_ARGUMENT", "Identity path is required", null)
                    return
                }
                try {
                    val identityFile = File(identityPath)
                    if (!identityFile.exists()) {
                        result.error("FILE_NOT_FOUND", "Identity file not found", null)
                        return
                    }
                    zitiContext = Ziti.newContext(identityFile)
                    result.success(true)
                } catch (e: ZitiException) {
                    result.error("INITIALIZATION_ERROR", e.message, null)
                }
            }
            "connectToService" -> {
                val serviceName = call.argument<String>("serviceName")
                if (serviceName == null) {
                    result.error("INVALID_ARGUMENT", "Service name is required", null)
                    return
                }
                try {
                    if (zitiContext == null) {
                        result.error("NOT_INITIALIZED", "Ziti not initialized", null)
                        return
                    }
                    
                    // Connect to the service
                    val future = CompletableFuture<ZitiService>()
                    zitiContext?.connect(serviceName) { service, error ->
                        if (error != null) {
                            future.completeExceptionally(error)
                        } else {
                            future.complete(service)
                        }
                    }
                    
                    currentService = future.get()
                    result.success(true)
                } catch (e: Exception) {
                    result.error("CONNECTION_ERROR", e.message, null)
                }
            }
            "disconnect" -> {
                try {
                    currentService?.close()
                    currentService = null
                    zitiContext?.close()
                    zitiContext = null
                    result.success(true)
                } catch (e: Exception) {
                    result.error("DISCONNECT_ERROR", e.message, null)
                }
            }
            "getConnectionStatus" -> {
                result.success(
                    when {
                        currentService != null -> "CONNECTED"
                        zitiContext != null -> "INITIALIZED"
                        else -> "DISCONNECTED"
                    }
                )
            }
            else -> {
                result.notImplemented()
            }
        }
    }
} 