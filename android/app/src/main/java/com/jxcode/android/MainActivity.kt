package com.jxcode.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import com.jxcode.android.ui.JXCodeRoot
import com.jxcode.android.ui.theme.JXCodeTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        setContent {
            JXCodeTheme {
                JXCodeRoot()
            }
        }
    }
}
