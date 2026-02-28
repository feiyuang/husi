package fr.husi.ui.profile

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.AnnotatedString
import fr.husi.compose.SimpleIconButton
import fr.husi.plugin.PluginOptions
import fr.husi.resources.Res
import fr.husi.resources.*
import me.zhanghai.compose.preference.*
import org.jetbrains.compose.resources.stringResource
import org.jetbrains.compose.resources.vectorResource

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ObfsLocalConfigScreen(
    initialConfig: String,
    onSave: (String) -> Unit,
    onBack: () -> Unit,
) {
    ProvidePreferenceLocals {
        val initialOptions = remember(initialConfig) { PluginOptions(initialConfig) }
        var obfsValue by remember {
            mutableStateOf(
                when {
                    initialOptions["mode"] == "http" -> "http"
                    initialOptions["obfs"] == "tls" -> "tls"
                    else -> "http"
                }
            )
        }
        var hostValue by remember { mutableStateOf(initialOptions["host"] ?: initialOptions["obfs-host"] ?: "cloudfront.net") }

        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("Simple obfuscation") },
                    navigationIcon = {
                        SimpleIconButton(
                            imageVector = vectorResource(Res.drawable.arrow_back),
                            contentDescription = "Back",
                            onClick = onBack,
                        )
                    },
                    actions = {
                        SimpleIconButton(
                            imageVector = vectorResource(Res.drawable.done),
                            contentDescription = stringResource(Res.string.apply),
                            onClick = {
                                val result = PluginOptions().apply {
                                    put("obfs", obfsValue)
                                    putWithDefault("obfs-host", hostValue, "cloudfront.net")
                                }
                                onSave(result.toString())
                            },
                        )
                    },
                )
            },
        ) { innerPadding ->
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                LazyColumn(contentPadding = innerPadding) {
                    item {
                        ListPreference(
                            value = obfsValue,
                            values = listOf("http", "tls"),
                            onValueChange = { obfsValue = it },
                            title = { Text(stringResource(Res.string.obfs)) },
                            summary = { Text(obfsValue) },
                            type = ListPreferenceType.DROPDOWN_MENU,
                            valueToText = { AnnotatedString(it) },
                        )
                    }
                    item {
                        TextFieldPreference(
                            value = hostValue,
                            onValueChange = { hostValue = it },
                            title = { Text(stringResource(Res.string.obfs_param)) },
                            summary = { Text(hostValue) },
                            textToValue = { it },
                            valueToText = { it },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun V2RayPluginConfigScreen(
    initialConfig: String,
    onSave: (String) -> Unit,
    onBack: () -> Unit,
) {
    ProvidePreferenceLocals {
        val options = remember(initialConfig) { PluginOptions(initialConfig) }

        var modeValue by remember {
            mutableStateOf(
                when {
                    (options["mode"] ?: "websocket") == "quic" -> "quic-tls"
                    options["mode"] == null && "tls" in options -> "websocket-tls"
                    options["mode"] == "grpc" && "tls" !in options -> "grpc"
                    options["mode"] == "grpc" && "tls" in options -> "grpc-tls"
                    else -> "websocket-http"
                },
            )
        }
        var hostValue by remember { mutableStateOf(options["host"] ?: "cloudfront.com") }
        var pathValue by remember { mutableStateOf(options["path"] ?: "/") }
        var muxValue by remember { mutableStateOf(options["mux"] ?: "1") }
        var serviceNameValue by remember { mutableStateOf(options["serviceName"] ?: "") }
        var certRawValue by remember { mutableStateOf(options["certRaw"] ?: "") }
        var loglevelValue by remember { mutableStateOf(options["loglevel"] ?: "warning") }

        fun readMode(value: String): Pair<String?, Boolean> = when (value) {
            "websocket-http" -> Pair(null, false)
            "websocket-tls" -> Pair(null, true)
            "quic-tls" -> Pair("quic", false)
            "grpc" -> Pair("grpc", false)
            "grpc-tls" -> Pair("grpc", true)
            else -> Pair(null, false)
        }

        Scaffold(
            topBar = {
                TopAppBar(
                    title = { Text("v2ray-plugin") },
                    navigationIcon = {
                        SimpleIconButton(
                            imageVector = vectorResource(Res.drawable.arrow_back),
                            contentDescription = "Back",
                            onClick = onBack,
                        )
                    },
                    actions = {
                        SimpleIconButton(
                            imageVector = vectorResource(Res.drawable.done),
                            contentDescription = stringResource(Res.string.apply),
                            onClick = {
                                val (m, tls) = readMode(modeValue)
                                val result = PluginOptions().apply {
                                    putWithDefault("mode", m, null)
                                    if (tls) put("tls", null)
                                    putWithDefault("host", hostValue, "cloudfront.com")
                                    putWithDefault("path", pathValue, "/")
                                    putWithDefault("mux", muxValue, "1")
                                    if (m == "grpc") putWithDefault("serviceName", serviceNameValue, "")
                                    putWithDefault("certRaw", certRawValue.replace("\n", ""), "")
                                    putWithDefault("loglevel", loglevelValue, "warning")
                                }
                                onSave(result.toString())
                            },
                        )
                    },
                )
            },
        ) { innerPadding ->
            Surface(modifier = Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
                LazyColumn(contentPadding = innerPadding) {
                    item {
                        ListPreference(
                            value = modeValue,
                            values = listOf("websocket-http", "websocket-tls", "quic-tls", "grpc", "grpc-tls"),
                            onValueChange = { modeValue = it },
                            title = { Text(stringResource(Res.string.network)) },
                            summary = { Text(modeValue) },
                            type = ListPreferenceType.DROPDOWN_MENU,
                            valueToText = { AnnotatedString(it) },
                        )
                    }
                    item {
                        TextFieldPreference(
                            value = hostValue,
                            onValueChange = { hostValue = it },
                            title = { Text(stringResource(Res.string.ws_host)) },
                            summary = { Text(hostValue) },
                            textToValue = { it },
                            valueToText = { it },
                        )
                    }
                    item {
                        val (m, _) = readMode(modeValue)
                        TextFieldPreference(
                            value = pathValue,
                            onValueChange = { pathValue = it },
                            title = { Text(stringResource(Res.string.ws_path)) },
                            summary = { Text(pathValue) },
                            textToValue = { it },
                            valueToText = { it },
                            enabled = m == null,
                        )
                    }
                    item {
                        val (m, _) = readMode(modeValue)
                        TextFieldPreference(
                            value = serviceNameValue,
                            onValueChange = { serviceNameValue = it },
                            title = { Text(stringResource(Res.string.grpc_service_name)) },
                            summary = { Text(serviceNameValue) },
                            textToValue = { it },
                            valueToText = { it },
                            enabled = m == "grpc",
                        )
                    }
                    item {
                        val (m, _) = readMode(modeValue)
                        TextFieldPreference(
                            value = muxValue,
                            onValueChange = { muxValue = it },
                            title = { Text(stringResource(Res.string.mux_strategy)) }, // Strategy reused as mux number title
                            summary = { Text(muxValue) },
                            textToValue = { it },
                            valueToText = { it },
                            enabled = m == null,
                        )
                    }
                    item {
                        val (m, tls) = readMode(modeValue)
                        TextFieldPreference(
                            value = certRawValue,
                            onValueChange = { certRawValue = it },
                            title = { Text(stringResource(Res.string.certificates)) },
                            summary = { Text(if (certRawValue.isBlank()) "Not set" else "Set") },
                            textToValue = { it },
                            valueToText = { it },
                            enabled = (m == null && tls) || (m == "quic") || (m == "grpc" && tls),
                        )
                    }
                    item {
                        ListPreference(
                            value = loglevelValue,
                            values = listOf("debug", "info", "warning", "error", "none"),
                            onValueChange = { loglevelValue = it },
                            title = { Text(stringResource(Res.string.log_level)) },
                            summary = { Text(loglevelValue) },
                            type = ListPreferenceType.DROPDOWN_MENU,
                            valueToText = { AnnotatedString(it) },
                        )
                    }
                }
            }
        }
    }
}
