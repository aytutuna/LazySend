package com.lazysend.lazysend.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lazysend.lazysend.R
import com.lazysend.lazysend.transfer.PhotoFormat

@Composable
fun formatLabel(format: PhotoFormat) = stringResource(
    when (format) {
        PhotoFormat.Jpeg -> R.string.format_jpeg
        PhotoFormat.Original -> R.string.format_original
        PhotoFormat.Png -> R.string.format_png
    },
)

/** The three formats as menu items, the current one ticked. */
@Composable
fun FormatItems(current: PhotoFormat, onPick: (PhotoFormat) -> Unit) {
    PhotoFormat.entries.forEach { format ->
        DropdownMenuItem(
            text = { Text(formatLabel(format)) },
            trailingIcon = { if (format == current) Icon(painterResource(R.drawable.ic_check), null) },
            onClick = { onPick(format) },
        )
    }
}

/** The + of the Files tab: pick photos or files to send now, send the whole library, or choose what photos are sent as. */
@Composable
fun AddButton(format: PhotoFormat, galleryEnabled: Boolean, onGallery: () -> Unit, actions: MainActions, modifier: Modifier = Modifier) {
    var open by remember { mutableStateOf(false) }
    var choosing by remember { mutableStateOf(false) }
    Box(modifier) {
        FilledTonalIconButton(onClick = { choosing = false; open = true }, Modifier.size(56.dp)) {
            Icon(painterResource(R.drawable.ic_add), stringResource(R.string.add_description))
        }
        DropdownMenu(open, { open = false }) {
            if (choosing) {
                FormatItems(format) {
                    open = false
                    actions.onFormat(it)
                }
            } else {
                DropdownMenuItem(text = { Text(stringResource(R.string.add_photos)) }, onClick = { open = false; actions.onPhotos() })
                DropdownMenuItem(text = { Text(stringResource(R.string.add_files)) }, onClick = { open = false; actions.onFiles() })
                DropdownMenuItem(text = { Text(stringResource(R.string.send_all_photos)) }, enabled = galleryEnabled, onClick = { open = false; onGallery() })
                DropdownMenuItem(text = { Text(stringResource(R.string.format_menu, formatLabel(format))) }, onClick = { choosing = true })
            }
        }
    }
}

/** Who a send goes to; the same chip is on the camera, over the picture, and on the Files tab. */
@Composable
fun TargetChip(current: PcRow, all: List<PcRow>, onSelect: (String) -> Unit, container: Color, content: Color, showLink: Boolean = false) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.clip(RoundedCornerShape(50)).background(container).clickable { open = true }.padding(horizontal = 14.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // A phone that connects to this one has no link to show.
            if (showLink && !current.guest) {
                val connected = current.link != null
                val state = stringResource(if (connected) R.string.connected else R.string.not_connected)
                Box(
                    Modifier.padding(end = 8.dp).size(8.dp).background(if (connected) Color(0xFF34C759) else Color(0xFFFF3B30), CircleShape)
                        .semantics { contentDescription = state },
                )
            }
            Text(current.name, color = content, style = MaterialTheme.typography.labelLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
        }
        DropdownMenu(open, { open = false }) {
            all.forEach { row ->
                DropdownMenuItem(
                    text = { Text(row.name) },
                    trailingIcon = { if (row.id == current.id) Icon(painterResource(R.drawable.ic_check), null) },
                    onClick = {
                        open = false
                        onSelect(row.id)
                    },
                )
            }
        }
    }
}
