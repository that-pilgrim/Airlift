package com.example.hotspot;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.Settings;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkRequest;
import android.net.wifi.SoftApConfiguration;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class HotspotProxy extends CordovaPlugin {
    private static final int PERM_REQ = 77;
    private static final int[] PORTS = {8080, 1080};

    private static WifiManager.LocalOnlyHotspotReservation reservation;
    private static ConnectivityManager cm;
    private static ConnectivityManager.NetworkCallback cellCallback;
    private static volatile Network cellular;
    private static final List<ServerSocket> servers = new ArrayList<>();
    private static ExecutorService pool;
    private CallbackContext pending;
    private boolean optForeground = true, optWake = true;
    private static JSONObject lastInfo;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext cb) throws JSONException {
        switch (action) {
            case "start":
                pending = cb;
                JSONObject o = args.optJSONObject(0);
                optForeground = o == null || o.optBoolean("foreground", true);
                optWake = o == null || o.optBoolean("wakelock", true);
                if (hasPerms()) doStart(); else requestPerms();
                return true;
            case "batteryStatus":
                cb.success(batteryExempt() ? 1 : 0);
                return true;
            case "batteryExempt":
                if (!batteryExempt()) {
                    Context c = cordova.getActivity();
                    Intent bi = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                            Uri.parse("package:" + c.getPackageName()));
                    cordova.getActivity().startActivity(bi);
                }
                cb.success();
                return true;
            case "stop":
                doStop();
                cb.success();
                return true;
            case "status":
                JSONObject s = lastInfo != null ? new JSONObject(lastInfo.toString()) : new JSONObject();
                s.put("running", reservation != null);
                cb.success(s);
                return true;
        }
        return false;
    }

    private static final String NOTIF = "android.permission.POST_NOTIFICATIONS";

    private String[] requiredPerms() {
        List<String> p = new ArrayList<>();
        p.add("android.permission.ACCESS_FINE_LOCATION");
        if (Build.VERSION.SDK_INT >= 33) p.add("android.permission.NEARBY_WIFI_DEVICES");
        return p.toArray(new String[0]);
    }

    private String[] requestList() {
        List<String> p = new ArrayList<>();
        Collections.addAll(p, requiredPerms());
        if ((optForeground || optWake) && Build.VERSION.SDK_INT >= 33) p.add(NOTIF);
        return p.toArray(new String[0]);
    }

    private boolean hasPerms() {
        for (String p : requestList()) if (!cordova.hasPermission(p)) return false;
        return true;
    }

    private void requestPerms() {
        cordova.requestPermissions(this, PERM_REQ, requestList());
    }

    @Override
    public void onRequestPermissionResult(int code, String[] perms, int[] results) {
        if (code != PERM_REQ || pending == null) return;
        for (int i = 0; i < perms.length && i < results.length; i++) {
            if (NOTIF.equals(perms[i])) continue;   // notification permission is optional
            if (results[i] != PackageManager.PERMISSION_GRANTED) {
                pending.error("Permission denied. Location/Nearby devices permission is required to create a hotspot.");
                pending = null;
                return;
            }
        }
        doStart();
    }

    private boolean batteryExempt() {
        Context c = cordova.getActivity();
        PowerManager pm = (PowerManager) c.getSystemService(Context.POWER_SERVICE);
        return pm.isIgnoringBatteryOptimizations(c.getPackageName());
    }

    private void startKeepAlive(Context ctx) {
        Intent i = new Intent(ctx, ProxyService.class);
        i.putExtra("wake", optWake);
        try {
            ctx.startForegroundService(i);
        } catch (Exception ignored) { /* hotspot still works, just without background protection */ }
    }

    private void stopKeepAlive() {
        try {
            Context ctx = cordova.getActivity().getApplicationContext();
            ctx.stopService(new Intent(ctx, ProxyService.class));
        } catch (Exception ignored) {}
    }

    private void doStart() {
        final Context ctx = cordova.getActivity().getApplicationContext();
        if (reservation != null) { pending.error("Already running"); return; }
        if (optForeground || optWake) startKeepAlive(ctx);

        // 1. Ask Android for a cellular network handle so the proxy can force traffic over mobile data.
        cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
        NetworkRequest req = new NetworkRequest.Builder()
                .addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build();
        cellCallback = new ConnectivityManager.NetworkCallback() {
            @Override public void onAvailable(Network n) { cellular = n; }
            @Override public void onLost(Network n) { if (n.equals(cellular)) cellular = null; }
        };
        cm.requestNetwork(req, cellCallback);

        // 2. Start the local-only hotspot.
        WifiManager wm = (WifiManager) ctx.getSystemService(Context.WIFI_SERVICE);
        try {
            wm.startLocalOnlyHotspot(new WifiManager.LocalOnlyHotspotCallback() {
                @Override
                public void onStarted(WifiManager.LocalOnlyHotspotReservation res) {
                    reservation = res;
                    try {
                        startProxy();
                        lastInfo = buildInfo(res);
                        pending.success(lastInfo);
                    } catch (Exception e) {
                        pending.error("Proxy failed: " + e.getMessage());
                        doStop();
                    }
                }
                @Override
                public void onFailed(int reason) {
                    pending.error("Hotspot failed (code " + reason + "). Turn on Location, turn off Wi-Fi tethering/other hotspots, and try again.");
                    doStop();
                }
                @Override
                public void onStopped() { doStop(); }
            }, new Handler(Looper.getMainLooper()));
        } catch (Exception e) {
            pending.error("Could not start hotspot: " + e.getMessage());
            doStop();
        }
    }

    @SuppressWarnings("deprecation")
    private JSONObject buildInfo(WifiManager.LocalOnlyHotspotReservation res) throws Exception {
        String ssid, pass;
        if (Build.VERSION.SDK_INT >= 30) {
            SoftApConfiguration c = res.getSoftApConfiguration();
            ssid = c.getSsid();
            pass = c.getPassphrase();
        } else {
            WifiConfiguration c = res.getWifiConfiguration();
            ssid = c.SSID;
            pass = c.preSharedKey;
        }
        JSONArray ips = new JSONArray();
        for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
            if (!ni.isUp() || ni.isLoopback()) continue;
            String n = ni.getName();
            if (n.startsWith("rmnet") || n.startsWith("ccmni") || n.startsWith("v4-") || n.startsWith("tun") || n.startsWith("dummy")) continue;
            for (InetAddress a : Collections.list(ni.getInetAddresses())) {
                if (a instanceof Inet4Address) ips.put(a.getHostAddress());
            }
        }
        JSONObject o = new JSONObject();
        o.put("ssid", ssid);
        o.put("password", pass);
        o.put("ips", ips);
        o.put("httpPort", PORTS[0]);
        o.put("socksPort", PORTS[1]);
        return o;
    }

    private void doStop() {
        stopKeepAlive();
        try { if (reservation != null) reservation.close(); } catch (Exception ignored) {}
        reservation = null;
        for (ServerSocket ss : servers) { try { ss.close(); } catch (Exception ignored) {} }
        servers.clear();
        if (pool != null) pool.shutdownNow();
        pool = null;
        try { if (cm != null && cellCallback != null) cm.unregisterNetworkCallback(cellCallback); } catch (Exception ignored) {}
        cellCallback = null;
        cellular = null;
        lastInfo = null;
    }

    // ---------------- Proxy ----------------

    private void startProxy() throws IOException {
        pool = Executors.newCachedThreadPool();
        final ExecutorService p = pool;
        for (int port : PORTS) {
            final ServerSocket ss = new ServerSocket();
            ss.setReuseAddress(true);
            ss.bind(new InetSocketAddress(port));
            servers.add(ss);
            p.execute(() -> {
                while (!ss.isClosed()) {
                    try {
                        final Socket c = ss.accept();
                        p.execute(() -> handle(c));
                    } catch (IOException e) { break; }
                }
            });
        }
    }

    private void handle(Socket client) {
        try {
            BufferedInputStream in = new BufferedInputStream(client.getInputStream());
            OutputStream out = client.getOutputStream();
            in.mark(1);
            int first = in.read();
            in.reset();
            if (first == -1) { close(client); return; }
            if (first == 5) { handleSocks5(client, in, out); return; }   // SOCKS5
            String head = readHead(in);
            if (head == null) { close(client); return; }
            String[] lines = head.split("\r\n");
            String[] rl = lines[0].split(" ");
            if (rl.length < 3) { close(client); return; }

            Network net = cellular;
            if (net == null) {
                out.write("HTTP/1.1 503 No Mobile Data\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                close(client);
                return;
            }

            if (rl[0].equalsIgnoreCase("CONNECT")) {
                int i = rl[1].lastIndexOf(':');
                String host = i > 0 ? rl[1].substring(0, i) : rl[1];
                int port = i > 0 ? Integer.parseInt(rl[1].substring(i + 1)) : 443;
                Socket remote = open(net, host, port);
                out.write("HTTP/1.1 200 Connection Established\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
                out.flush();
                pipe(client, in, out, remote);
            } else {
                URL u = new URL(rl[1]);
                int port = u.getPort() == -1 ? 80 : u.getPort();
                String path = u.getFile().isEmpty() ? "/" : u.getFile();
                Socket remote = open(net, u.getHost(), port);
                StringBuilder sb = new StringBuilder(rl[0] + " " + path + " " + rl[2] + "\r\n");
                for (int i = 1; i < lines.length; i++) {
                    String low = lines[i].toLowerCase();
                    if (low.startsWith("proxy-connection:") || low.startsWith("connection:")) continue;
                    sb.append(lines[i]).append("\r\n");
                }
                sb.append("Connection: close\r\n\r\n");
                remote.getOutputStream().write(sb.toString().getBytes(StandardCharsets.ISO_8859_1));
                remote.getOutputStream().flush();
                pipe(client, in, out, remote);
            }
        } catch (Exception e) {
            try {
                client.getOutputStream().write("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            } catch (Exception ignored) {}
            close(client);
        }
    }

    private void handleSocks5(Socket client, BufferedInputStream in, OutputStream out) throws IOException {
        byte[] h = readN(in, 2);                    // VER, NMETHODS
        readN(in, h[1] & 0xff);                     // methods (we only offer "no auth")
        out.write(new byte[]{5, 0});
        out.flush();

        byte[] r = readN(in, 4);                    // VER CMD RSV ATYP
        if (r[0] != 5 || r[1] != 1) {               // only TCP CONNECT is supported
            out.write(new byte[]{5, 7, 0, 1, 0, 0, 0, 0, 0, 0});
            out.flush();
            close(client);
            return;
        }
        InetAddress ip = null;
        String host = null;
        if (r[3] == 1) ip = InetAddress.getByAddress(readN(in, 4));
        else if (r[3] == 4) ip = InetAddress.getByAddress(readN(in, 16));
        else if (r[3] == 3) host = new String(readN(in, readN(in, 1)[0] & 0xff), StandardCharsets.ISO_8859_1);
        else {
            out.write(new byte[]{5, 8, 0, 1, 0, 0, 0, 0, 0, 0});
            out.flush();
            close(client);
            return;
        }
        byte[] pb = readN(in, 2);
        int port = ((pb[0] & 0xff) << 8) | (pb[1] & 0xff);

        Socket remote;
        try {
            Network net = cellular;
            if (net == null) throw new IOException("no mobile data");
            remote = open(net, ip != null ? ip : net.getByName(host), port);   // DNS over mobile data
        } catch (IOException e) {
            out.write(new byte[]{5, 4, 0, 1, 0, 0, 0, 0, 0, 0});               // host unreachable
            out.flush();
            close(client);
            return;
        }
        out.write(new byte[]{5, 0, 0, 1, 0, 0, 0, 0, 0, 0});                   // success
        out.flush();
        pipe(client, in, out, remote);
    }

    private byte[] readN(InputStream in, int n) throws IOException {
        byte[] b = new byte[n];
        int off = 0;
        while (off < n) {
            int k = in.read(b, off, n - off);
            if (k < 0) throw new IOException("EOF");
            off += k;
        }
        return b;
    }

    private Socket open(Network net, InetAddress addr, int port) throws IOException {
        Socket s = new Socket();
        net.bindSocket(s);
        s.connect(new InetSocketAddress(addr, port), 15000);
        return s;
    }

    private Socket open(Network net, String host, int port) throws IOException {
        InetAddress addr = net.getByName(host);   // DNS over mobile data
        Socket s = new Socket();
        net.bindSocket(s);                         // force traffic over mobile data
        s.connect(new InetSocketAddress(addr, port), 15000);
        return s;
    }

    private String readHead(InputStream in) throws IOException {
        ByteArrayOutputStream buf = new ByteArrayOutputStream();
        int state = 0, b;
        while (buf.size() < 65536 && (b = in.read()) != -1) {
            buf.write(b);
            if (b == '\r' && (state == 0 || state == 2)) state++;
            else if (b == '\n' && (state == 1 || state == 3)) state++;
            else state = 0;
            if (state == 4) return buf.toString("ISO-8859-1");
        }
        return null;
    }

    private void pipe(final Socket a, final InputStream aIn, final OutputStream aOut, final Socket b) throws IOException {
        final InputStream bIn = b.getInputStream();
        final OutputStream bOut = b.getOutputStream();
        pool.execute(() -> copy(aIn, bOut, a, b));
        copy(bIn, aOut, a, b);
    }

    private void copy(InputStream in, OutputStream out, Socket a, Socket b) {
        byte[] buf = new byte[16384];
        try {
            int n;
            while ((n = in.read(buf)) != -1) { out.write(buf, 0, n); out.flush(); }
        } catch (IOException ignored) {
        } finally { close(a); close(b); }
    }

    private void close(Socket s) { try { s.close(); } catch (Exception ignored) {} }
}
