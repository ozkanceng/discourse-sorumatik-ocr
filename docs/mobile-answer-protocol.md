# Mobil canlı cevap: protokol 2 ve yayınlama

## Akış ve sahiplik

Yeni mobil kaynak mesajı `client_edge_solve=true` ve
`mobile_answer_protocol=2` ile oluşturulur. Uygulama önce
`GET /sorumatik/ai-config` yanıtında `enabled=true` ve protokol >=2 desteğini
doğrular. Sunucu, bu iki alanı PostCreator mesajı oluştururken custom fields
olarak saklar; `post_created` olayından sonra işaretlemek yeterli değildir.

İlk cevap, normal devam cevabı ve hızlı cevap seçeneği aynı uygulama oturumunu
kullanır. Gemini uygulamaya metin gönderir. Üretim tamamlanınca **aynı nihai
metin** Discourse'a kaydedilir. Versiyonlu mobil kaynak için
`ManagedAiReply` ve FCM native streaming adapter'ı üretimi başlatmaz;
`POST /sorumatik/ai-generations` ve eski SSE üretim girişleri `409
client_owned_source` döndürür. Discourse'a yalnız bitmiş cevap yayımlanır.
Kayıt olayı ve FCM bildirimi devam eder.

Eski istemci ve web kaynakları mevcut sunucu üretimi / MessageBus / durum
sorgusu yolunda kalır. Protokol desteği bulunmayan sunucuda yeni mobil devam
cevabı bu uyumluluk yolunu kullanır. Eski ilk-cevap `save-solution` yanıtı
yalnız post numarası içeriyorsa istemci postu getirip tam metni doğrular.
Eski kaynaklara protokol 2'nin çift üretim garantisi uygulanamaz.

## Kayıt sözleşmesi

`POST /sorumatik/save-solution` alanları: `topic_id`, `source_post_id`,
`content`, `content_sha256`. Kullanıcı kaynağın sahibi olmalı, kaynağa ve
konuya erişebilmelidir. Hash verilen metnin UTF-8 SHA-256 değeridir.

- `200`: `state=completed`, `generation_id`, `topic_id`, `source_post_id`,
  `raw`, `content_sha256`, `post_id`, `post_number`. İstemci durum, kaynak,
  konu, tam metin, hash ve post kimliğini doğrular.
- `202`: hazır metnin kaydı sürüyor. Aynı `generation_id` ile GET izlenir.
  Kayıt kimliği gelmesi tek başına tamamlanma değildir.
- Aynı kaynağa aynı içerik yinelenirse aynı post döner. Tamamlanmış farklı
  içerik `409 answer_conflict` verir; önceki post değiştirilmez.
- Kayıt hatasında tam metin kalır. Yeniden deneme yalnız kayıt işlemini
  yapar; Gemini çağırmaz. Sunucudaki kaynak ve üretim kilitleri aynı sırayla
  alınır; post oluşturma ve tamamlanma tek transaction içindedir.

`GET /sorumatik/ai-generations/by-source/:source_post_id` kaynak durumunu,
`GET /sorumatik/ai-generations/:generation_id` kayıt durumunu verir. Konu
sayfasının ilk sayfasında olmayan cevap ayrıca post kimliğiyle alınır.
İstemci oturum kimliği ile sunucunun `generation_id` değeri ayrı alanlardır.

FCM tamamlanma kanıtı değildir. İstemci ilgili kaynağın gerçek postunu alıp
mevcut oturumla birleştirir. Erken veya yinelenen bildirim yeni cevap üretmez;
bildirim kaybolsa da kayıt sonucunun izlenmesi tamamlanmayı sağlar.

## Oturum, kesinti ve görünüm

`AiAnswerSessionRegistry` üretimi ekran yaşam döngüsünden ayırır. Kullanıcı /
konu oturumunda tek bekleyen kaynak tutulur; kayıt bitmeden yeni AI eylemleri
kapalıdır, mesaj taslağı yazılabilir. Kaynak kimliği tüm taşıma ve disk
kayıtlarında doğrulanır. Sayfa kapanması, lazy-list satırının kaldırılması
ve geri dönüş üretimi sıfırlamaz.

Taslaklar kullanıcı adının hash'i altındaki uygulama destek klasöründe ayrı
konu-kaynak JSON dosyalarıdır. İçerik atomik geçici dosya + rename ile yazılır;
üretim sırasında yaklaşık 500 ms'de bir checkpoint ve gönderimden önce
tamamlanmış metin kaydı yapılır. API anahtarı ve görseller saklanmaz.
Logout bağlantıları durdurup kullanıcıya ait dosyaları temizler.

Uygulama açılışında bekleyen kayıtlar ekran açılmasa da toparlanır. Önce
sunucu kaydı kontrol edilir; tamamlanmış yerel metin yalnız kaydedilir.
Kısmi yerel metin önce görünür olur, açık bir yeniden deneme durumu gösterir.
Uygulama tamamen kapalıyken üretimin bitirilmesi kapsam dışındadır.

İlk metinden önce sınırlı geçici bağlantı tekrarı yapılır. Metin geldikten
sonra kesinti taslağı korur ve `Yanıt kesildi — Yeniden dene` gösterir.
`Durdur` HTTP üretimini iptal eder, taslağı tutar ve yayımlamaz. Açık yeniden
üretim eski kısmi metni temizleyerek aynı kaynağa yeni yerel oturum başlatır.

Bağlam ilk soru, cevaplanan mesaj ve kaynağa kadar son 20 görünür mesajdan
oluşur; gerekli sayfalar ayrıca alınır. Kullanıcı/model rolleri korunur.
Gizli/silinmiş mesajlar ve kaynaktan sonraki mesajlar dahil edilmez. Gerekli
görsel alınamıyorsa sessiz eksik bağlamla üretim yapılmaz.

Canlı kart `answer-sourceId` anahtarını kayıtlı karta geçerken korur. Postlar
kimlikle birleştirilir; eski HTTP yanıtı yeni postları silemez. Gerçek silme
ayrı işlenir. Sonuç mesaj sayısıyla değil kaynak ilişkisiyle eşleştirilir.

Takip açıksa son metin satırı ölçülen cevap gövdesi ve composer/klavye
konumuna göre görünür tutulur; tamamlanma Benzer Konular'a kaydırmaz.
Kullanıcı kaydırınca takip durur; `Yeni yanıta git` yeniden açar. Kayda
geçişte okunan konum korunur. Ekran dışında kalan kart ölçülene kadar
viewport adımlarıyla bulunur; sabit tahmini kart yüksekliği kullanılmaz.

Yazı 50 ms aralığında grapheme kümeleriyle ilerler. Birikmiş metin adaptif
boşaltılır ve üretim sonunda tam metin gösterilir. Emoji/birleşik karakter
bölünmez; hareket azaltma açıkken animasyon atlanır. İmleç Markdown dışında
çizilir. Aynı `AiAnswerBody`, değişmeyen HTML'i önbellekleyerek canlı, kayıtlı
ve yeniden açılan Markdown/LaTeX içeriğini aynı biçimde gösterir.

## Yayın sırası

1. Staging'de Discourse sürümü, bot hesabı, model/prompt ayarları ve iki
   eklentinin yüklü olduğunu doğrula. Eski çalışan işleri tamamlat.
2. `discourse-sorumatik-ocr` ile `discourse-fcm-notifications` değişikliklerini
   birlikte yayımla. Normal Discourse yükseltmesiyle
   `20261003000000_create_sorumatik_ai_generations` migration'ını çalıştır;
   web ve Sidekiq süreçlerini yeni kodla başlat.
3. Config'te `mobile_answer_protocol: 2` doğrula. Yeni soru ve devam mesajının
   custom fields değerleri **post_created sırasında** mevcut olmalı.
   `DiscourseAi::AiBot::Playground.ancestors` içinde iki adapter'ı doğrula.
   Versiyonlu mobil kaynakta native çağrı / canlı Discourse taslağı
   oluşmamalı; üretim girişleri 409, import ise tek kayıt döndürmeli.
4. Aşağıdaki Rails spec'leri ve staging kabul senaryolarını çalıştır.
   Ardından mobil istemciyi yayımla. Eski server-streaming yüzde ayarları
   yalnız eski istemci/web uyumluluk yoluna aittir; mobil doğrudan akışın
   yayını bu ayarlarla yönetilmez.
5. Destek ilanını kapatmak yeni kaynakları uyumluluk yoluna yönlendirir.
   Önceden işaretlenmiş mobil kaynakların sahipliğini değiştirme; bekleyen
   kayıt endpoint'lerini ve veritabanını koru. Kayıt kuyruğu bitmeden sunucu
   eklentisini eski sürüme döndürme.

9 Ekim 2026 kontrolünde canlı `sorumatik.co` config'i protokol sürümü ilan
etmiyordu. Bu çalışma kod ve yerel build içerir; sunucuya dağıtım yapılmadı.

## Ölçüm ve kabul

`AI_STREAM_METRIC` mobil ilk snapshot, ilk metin, çizim gecikmesi, tamamlanma,
kayıt süresi, kayıt hatası/kesinti ve yinelenen kayıt metadatasını verir.
Metin, görsel ve API anahtarı bu ölçümlere yazılmaz. Sunucu import/kayıt
ölçümleri `sorumatik_ai_metrics` ile izlenir. Eski
`tools/report_ai_generation_latency.py` sunucu üretimi analizi içindir;
mobil doğrudan üretimi sunucu `first_text_ms` üzerinden değerlendirme.

Kabulde ilk soru, normal devam ve hızlı cevap için Gemini bitişi, gösterim,
200/202 kaydı ve FCM'nin farklı sıralarını dene. Tek görünür kart / tek post
olmalı. Kayıt timeout/503/409, eşzamanlı aynı import, görünür olmayan post,
FCM yokluğu/tekrarı, kesinti, durdurma, yeniden açılış ve logout'u kapsa.
Kayıt tekrarında sağlayıcı çağrı sayısı sıfır artmalı. Yukarı kaydırma,
sayfadan çıkıp dönme, klavye ve geç konu isteği konumu/metni bozmamalı.

Türkçe, emoji/birleşik karakter, uzun metin, tablo, kod, LaTeX ile gerçek
cihazda profile build frame süreleri ve bellek ölçülmeli. Simülatör/debug
sonucu akıcılık onayı değildir. İlk metin ve kayıt sürelerinin p50/p95
değerleri ağ/cihaz/sürüm bazında raporlanmalı; unit test süreleri model
performansı sayılmamalıdır.

Yerel Flutter yaşam döngüsü testleri: `mobile_answer_lifecycle_test`,
`ai_generation_client_test`, `ai_live_answer_provider_test`,
`ai_live_topic_trigger_test`, `ai_answer_body_test`, `gemini_live_client_test`,
`topic_feed_rows_ad_test`, `api_service_create_topic_test`.
Mevcut parser/uyumluluk testleri ayrıca korunur. Açık/koyu tema görsel
testleri canlı, kayıtlı ve yeniden açılan gövdelerin aynı pikselleri
üretmesini denetler. Ruby sağlayıcı testleri Rails olmadan çalışır:

```sh
cd output/discourse-sorumatik-ocr
ruby test/gemini_answer_stream_test.rb
```

Discourse geliştirme ortamı kökünde:

```sh
LOAD_PLUGINS=1 bundle exec rspec \
  plugins/discourse-sorumatik-ocr/spec/services/sorumatik_ocr/answer_generation_spec.rb \
  plugins/discourse-sorumatik-ocr/spec/requests/sorumatik_ocr/ai_generations_spec.rb \
  plugins/discourse-fcm-notifications/spec/lib/ai_answer_streaming_spec.rb
```

Bu makinede Discourse/Rails/PostgreSQL test ortamı bulunmadığından bu üç
entegrasyon spec'i ve gerçek cihaz performans profili burada çalıştırılmadı.
Staging kabulünde `displayed.raw == generation.raw == post.raw == reopened.raw`
eşitliği ile kaynak başına tek post ayrıca doğrulanmalıdır.

9 Ekim yerel doğrulaması: 82 canlı cevap / görünüm / API testi ve 50 mevcut
parser / servis uyumluluk testi geçti (toplam 132). AI üretimi kapalı ve
Gemini anahtarı boşken save-only toparlanma dahil 29 taşıma / yaşam döngüsü
testi son değişiklikten sonra tekrar geçti. Ruby sağlayıcı paketi 10 test,
26 assertion ile geçti. Değiştirilen Ruby dosyalarının sözdizimi kontrolü
geçti. Dart analizinde hata/uyarı yok; bilgi düzeyindeki mevcut lint'ler
devam ediyor. iOS simülatör debug build'i oluşturulup iPhone 16e'ye kuruldu.
695474 numaralı mevcut konuda ilk cevap ve kayıtlı özet cevabı görüntülendi;
yukarı/aşağı kaydırma döngüsünde özet kartı tekrar göründü. Konudan çıkıp
yeniden açınca ilk cevap sunucudan yüklendi. Bu kontroller kayıtlı içerik
kontrolleridir; canlı sunucu henüz protokol 2 bildirmediğinden yeni doğrudan
devam üretimi, FCM ve kayıt geçişi staging/canlı ortamda uçtan uca denenmedi.

PostCreator olay sırası için temel sözleşme:
[Discourse PostCreator](https://github.com/discourse/discourse/blob/main/lib/post_creator.rb).
