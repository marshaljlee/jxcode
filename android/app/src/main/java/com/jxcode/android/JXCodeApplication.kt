package com.jxcode.android

import android.app.Application

class JXCodeApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        // The sandbox home is scaffolding only: it must exist before any pty is
        // spawned, because a shell started with a $HOME that does not exist
        // silently falls back to / and every agent then writes to the wrong
        // place. Creating it at process start is the only point guaranteed to
        // precede both the UI and the router service.
        SandboxHome.ensure(this)
    }
}
