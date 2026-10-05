# OMID Railway Senai — Single Domain + Dynamic WS/XHTTP Routing

نسخه ساده و مخصوص Railway از 3x-ui / Senai.

## ویژگی‌ها

- بدون Tor
- بدون GeoIP و Country rotation
- بدون ساخت یا حذف خودکار Inbound
- Inboundها مستقیماً توسط کاربر داخل Senai ساخته می‌شوند
- پنل و Subscription روی یک Domain عمومی
- تشخیص خودکار `RAILWAY_PUBLIC_DOMAIN`
- Dynamic routing برای Inboundهای HTTP-based مانند WebSocket و XHTTP
- با ساخت/ویرایش/حذف Inbound، Routeهای Nginx هر ۵ ثانیه همگام می‌شوند
- Nginx فقط وقتی Routeها واقعاً تغییر کنند reload می‌شود

## مسیرهای عمومی

```text
https://DOMAIN/managepanel/       → Senai
https://DOMAIN/sub/<TOKEN>        → Subscription
https://DOMAIN/json/<TOKEN>       → JSON Subscription
https://DOMAIN/clash/<TOKEN>      → Clash Subscription
```

## Dynamic WS/XHTTP

مثلاً اگر داخل Senai بسازی:

```text
Port: 8080
Network: WS
Path: /ws
Security: none
```

Nginx به‌صورت خودکار می‌سازد:

```text
/ws → 127.0.0.1:8080
```

اگر بعداً بسازی:

```text
Port: 8081
Network: XHTTP
Path: /vless
Security: none
```

Route دوم نیز خودکار ساخته می‌شود.

### نکته مهم

برای عبور از Nginx، Inboundهای WS/XHTTP که قرار است از HTTPS عمومی استفاده کنند باید در سمت Xray پشت Nginx بدون TLS باشند (`Security: none`). TLS عمومی توسط Railway/Nginx مدیریت می‌شود.

Pathهای زیر رزرو هستند و برای Inbound استفاده نمی‌شوند:

```text
/managepanel
/sub
/json
/clash
/health
/ping
```

## Inboundهای TCP/UDP

پروژه Route HTTP را برای WS/XHTTP انجام می‌دهد. Inboundهای خام TCP/UDP همچنان نیازمند TCP Proxy/Networking خود Railway هستند و نباید انتظار داشت `DOMAIN:8080` مستقیماً همان پورت داخلی باشد.

## Deploy

1. این repository را روی Railway Deploy کن.
2. برای سرویس یک Public Domain از بخش Networking بساز.
3. نیاز به تنظیم `PUBLIC_DOMAIN` نیست؛ `RAILWAY_PUBLIC_DOMAIN` به‌صورت خودکار استفاده می‌شود.
4. داخل Senai Inbound خودت را بساز.
5. اگر Network آن WS یا XHTTP و Path مثلاً `/ws` باشد، Route آن به‌صورت خودکار ایجاد می‌شود.

## Environment اختیاری

```text
XUI_USERNAME=admin
XUI_PASSWORD=admin
XUI_API_TOKEN=
PUBLIC_DOMAIN=
```

`PUBLIC_DOMAIN` فقط برای override کردن Domain خودکار Railway است.
