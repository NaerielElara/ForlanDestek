# Forlan Destek sunucusu

Bu bilgisayardaki Docker Compose kurulumu, RustDesk Server OSS'nin ID (`hbbs`) ve relay (`hbbr`) servislerini çalıştırır. Sunucu adresi `95.70.196.174` olarak ayarlanmıştır.

```powershell
docker compose -f .\deploy\forlan-server\compose.yaml up -d
docker compose -f .\deploy\forlan-server\compose.yaml ps
docker compose -f .\deploy\forlan-server\compose.yaml logs --tail 50
```

Modemde `21115/TCP`, `21116/TCP+UDP` ve `21117/TCP` portları bu bilgisayarın yerel IP adresine yönlendirilmelidir. Web istemcisi kullanılmadığı için `21118` ve `21119` dışarıya açılmaz. Bilgisayar ve Docker Desktop çalışır durumda kalmalıdır.

Sunucunun özel anahtarı ve kayıtları `forlan_server_data` adlı Docker volume içinde saklanır. Bu volume silinirse sunucu anahtarı değişir ve eski istemcilerin anahtar ayarı geçersiz olur. Portable build yalnızca [genel anahtarı](id_ed25519.pub) kullanır.
