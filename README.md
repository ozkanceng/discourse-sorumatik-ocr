# Discourse Sorumatik OCR Plugin

Bu eklenti, Discourse üzerinden Google Gemini 2.5 Flash Lite modelini kullanarak doğrudan ve ultra hızlı Matematik/Sınav OCR desteği sunar.

## Özellikler
- **Thinking Budget = 0:** Modelin gereksiz düşünme döngüsü kapatılmıştır. Yanıt süresi ~600-900ms'dir.
- **Sıfır WordPress Bağımlılığı:** WordPress ve PHP-FPM bootstrap overhead'i tamamen devreden çıkar.
- **Yerel Yetkilendirme:** İstekler Discourse'un yerel `User-Api-Key` mekanizması ile doğrudan bellekte (Puma worker) onaylanır; harici HTTP yetkilendirme çağrısı yapılmaz.
- **Güvenli API Anahtarı:** Gemini API anahtarı Discourse SiteSetting veya sunucu ENV değişkeninde saklanır, istemciye (mobil uygulamaya) asla sızmaz.

---

## Kurulum (Discourse Sunucusunda)

### 1. Eklentiyi `app.yml` Dosyasına Ekleme

Discourse sunucunuza SSH ile bağlanın ve `/var/discourse/containers/app.yml` dosyasını düzenleyin:

```bash
cd /var/discourse
nano containers/app.yml
```

`hooks -> after_code` altındaki `plugins` listesine şu satırı ekleyin:

```yaml
hooks:
  after_code:
    - exec:
        cmd:
          - git clone https://github.com/ozkanceng/discourse-sorumatik-ocr.git
```

### 2. Ortam Değişkeni Tanımlama (Tavsiye Edilir)

`app.yml` dosyasındaki `env:` bloğuna Gemini API anahtarınızı ekleyin:

```yaml
env:
  GEMINI_API_KEY: "AIzaSy..." # Mevcut Google Gemini API anahtarınız
```

### 3. Konteyneri Yeniden Derleme

```bash
./launcher rebuild app
```

### 4. Yönetici Panelinden Kontrol (Discourse Admin)

Derleme tamamlandıktan sonra Discourse Yönetici Paneline gidin:
1. **Yönetici -> Ayarlar -> Eklentiler (Plugins)** sekmesini açın.
2. `gemini_ocr_enabled` kutusunun seçili olduğunu doğrulayın (varsayılan: açık).
3. `gemini_ocr_api_key` alanına Google Gemini API anahtarınızı girin (eğer ENV'ye tanımlamadıysanız).
4. Kaydedin.

---

## Endpoint Bilgisi

- **URL:** `POST https://sorumatik.co/sorumatik/ocr`
- **Headers:**
  - `User-Api-Key: <DISCOURSE_USER_API_KEY>`
  - `User-Api-Client-Id: sorumatik_mobile_v4`
- **Body (multipart/form-data):**
  - `image`: Görsel dosyası (JPEG veya PNG)
  - `lang`: `tr`


## Mobil canlı cevap protokolü 2

Mobil kaynak mesajlarında `client_edge_solve=true` ve `mobile_answer_protocol=2`
alanları mesaj oluşturulurken saklanır. Bu kaynaklar sunucuda veya Discourse AI
adapter'larında ikinci bir cevap üretmez. Tamamlanan mobil cevap
`save-solution` ile bir kez kaydedilir; aynı içerik aynı postu, farklı içerik
`409` sonucunu verir. Web ve eski istemci üretim yolu korunur.

Bu güncellemeyi yalnız
[`ozkanceng/discourse-fcm-notifications`](https://github.com/ozkanceng/discourse-fcm-notifications)
çatalındaki mobil sahiplik korumasıyla birlikte kurun. Önce iki sunucu
eklentisini güncelleyip Discourse'u rebuild edin; ardından yeni mobil
istemciyi yayımlayın. GitHub'a kod gönderilmesi sunucunun güncellenmesi değildir.

[Yayın sırası, API sözleşmesi ve kabul testleri](docs/mobile-answer-protocol.md).
