package com.jxcode.android.terminal

import java.io.File

object TermuxShell {
    fun resolveShell(): String {
        val termuxBash = File("/data/data/com.termux/files/usr/bin/bash")
        if (termuxBash.exists() && termuxBash.canExecute()) {
            return termuxBash.absolutePath
        }
        val termuxSh = File("/data/data/com.termux/files/usr/bin/sh")
        if (termuxSh.exists() && termuxSh.canExecute()) {
            return termuxSh.absolutePath
        }
        return "/system/bin/sh"
    }
}
