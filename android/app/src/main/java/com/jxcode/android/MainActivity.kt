package com.jxcode.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import com.jxcode.android.ui.JXCodeRoot
import com.jxcode.android.ui.theme.JXCodeTheme

class MainActivity : ComponentActivity() {

    /**
     * The router runs as a foreground service, and from Android 13 a service's
     * notification is only shown once POST_NOTIFICATIONS has been granted.
     * Without the grant the service still runs — Android does not kill it — but
     * there is nothing in the shade to say a model is loaded, and no visible
     * way to stop it. The manifest declares the permission; the runtime grant
     * can only come from here.
     */
    private val notificationPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        android.util.Log.i("JXCodeMain", "POST_NOTIFICATIONS granted=$granted")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
        setContent {
            JXCodeTheme {
                JXCodeRoot()
            }
        }
    }
}
