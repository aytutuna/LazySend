package com.lazysend.lazysend.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

private val Light = lightColorScheme(
    primary = Color(0xFF3F51B5),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFE0E3FF),
    onPrimaryContainer = Color(0xFF0A1470),
    secondaryContainer = Color(0xFFE3E5F5),
    surface = Color(0xFFFBF8FF),
    surfaceVariant = Color(0xFFE4E1EC),
)

private val Dark = darkColorScheme(
    primary = Color(0xFFB9C3FF),
    onPrimary = Color(0xFF14248A),
    primaryContainer = Color(0xFF2B3AA0),
    onPrimaryContainer = Color(0xFFE0E3FF),
)

@Composable
fun LazySendTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    MaterialTheme(colorScheme = if (dark) Dark else Light, content = content)
}
