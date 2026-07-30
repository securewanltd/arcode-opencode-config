# arcode-opencode-config

`arcode-opencode-config`, kurumsal ortamlarda opencode yapılandırmasını merkezi bir noktadan dağıtmak için yazılmış bir opencode eklentisidir. Eklenti, GitHub'da barındırılan bir manifest dosyasını indirir ve içinde tanımlı agent'ları ile MCP sunucularını opencode yapılandırmasına enjekte eder. Böylece onlarca geliştirici makinesindeki opencode.json dosyalarını tek tek güncellemeden, merkezi bir politika ile yapılandırma yönetimi sağlanır.

## Amaç

- **Merkezi yönetim:** Agent, model, sistem promptu ve MCP sunucu tanımları tek bir manifest dosyasında tutulur.
- **Kurumsal denetim:** GPO/Intune aracılığıyla `C:\ProgramData\opencode\opencode.json` dosyası dağıtılarak kullanıcı müdahalesi olmadan tüm ekibin opencode yapılandırması senkronize tutulur.
- **Çevrimdışı dayanıklılık:** Son başarılı manifest yerel diske önbelleğe yazılır; ağ hatası durumunda bu önbellekten devam edilir.

## Mimari

```text
┌─────────────────────────────────────────────────────────────────────────────────┐
│  GitHub / GitHub Enterprise                                                     │
│  securewanltd/arcode-opencode-config/main/manifest.json  ←  JSON Schema ile     │
│  doğrulanır                                                                      │
└──────────────────────────┬────────────────────────────────────────────────────────┘
                           │ fetch + Bearer token (isteğe bağlı)
                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  arcode-opencode-config eklentisi                                                │
│  - opencode.json içinde `plugin` dizisine tarball URL'si olarak tanımlı          │
│  - Başlangıçta manifesti çeker                                                   │
│  - Başarısız olursa ~/.cache/arcode-opencode-config/manifest.json kullanır        │
│  - cfg.agent, cfg.mcp ve cfg üst düzey anahtarlarına enjekte eder                │
└──────────────────────────┬────────────────────────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────────────────────┐
│  GPO ile dağıtılan opencode.json                                                  │
│  C:\ProgramData\opencode\opencode.json                                           │
│  { plugin: [["https://github.com/securewanltd/arcode-opencode-config/             │
│             archive/refs/heads/main.tar.gz",                                     │
│             { manifestUrl: "..." }]] }                                            │
└─────────────────────────────────────────────────────────────────────────────────┘
```

1. **GitHub manifest:** Bir organizasyon deposunda `manifest.json` tutulur. İçinde `agents`, `mcp` ve isteğe bağlı `config` tanımları yer alır.
2. **arcode-opencode-config eklentisi:** opencode açılır açılmaz `config` hook'u çalışır ve manifesti getirir.
3. **GPO yönetimi:** Yönetici, `managed-opencode.example.json` dosyasındaki gibi bir `opencode.json` yapılandırmasını kullanıcıların makinelerine dağıtır.

## Kurulum

Bu proje npm'de yayınlanmamıştır. opencode, plugin girdilerini bir GitHub tarball URL'sinden indirebilir; böylece hedef makinede git kurulu olmasına gerek kalmaz (npm'nin `github:owner/repo` spec'i git gerektirir).

opencode yapılandırmanıza eklentiyi tuple formunda ekleyin:

```json
{
  "plugin": [
    ["https://github.com/securewanltd/arcode-opencode-config/archive/refs/heads/main.tar.gz", {
      "manifestUrl": "https://raw.githubusercontent.com/securewanltd/arcode-opencode-config/main/manifest.json"
    }]
  ]
}
```

Kurumsal dağıtım için `managed-opencode.example.json` örneğini `C:\ProgramData\opencode\opencode.json` konumuna kopyalayın.

## Sıfır Makine İçin Tek Komut Kurulumu (Windows)

Yeni veya boş bir Windows makinesine Node.js, opencode CLI, tüm MCP ön koşulları ve plugin config'i tek adımda kurmak için `bootstrap.ps1` kullanın. Varsayılan repo `securewanltd/arcode-opencode-config`'tir; kendi fork'unuz veya farklı bir repo için `-Repo` ile geçersiz kılabilirsiniz.

```powershell
# Repo root'undan PowerShell'de yönetici hakları olmadan çalıştırın
.\bootstrap.ps1
```

Farklı bir repo kullanmak için:

```powershell
.\bootstrap.ps1 -Repo "fork-owner/arcode-opencode-config" -Branch "main"
```

`bootstrap.ps1` aşağıdaki adımları idempotent olarak yapar:

1. **Node.js / npm** kontrolü: Eksikse ve `winget` varsa `winget install OpenJS.NodeJS.LTS` ile kurar. Yeniden başlatma gerektirebilir; script devam eder ve son özet bildirir.
2. **git** kontrolü: Eksikse ve `winget` varsa `winget install Git.Git` ile kurar. Eklentinin kendisi tarball URL'si kullandığı için git şart değildir, ancak diğer `github:` spec ile yüklenen plugin'ler için git gerekebilir; bu yüzden kurulum denenir, başarısızlık durumunda sadece uyarı verilir ve script devam eder.
3. **opencode CLI** kontrolü/kurulumu: Eksikse `npm install -g opencode-ai` çalıştırır.
4. **MCP ön koşulları**:
   - `codegraph` CLI: Resmi installer (`irm ... | iex`) ile kurar, USER PATH'e ekler ve mevcut oturum PATH'ine prepends eder.
   - `@theupsider/lsp-mcp@1.3.2` ve `websearch-mcp`: Eksiklerse `npm install -g` ile kurar. (`lsp-mcp` adındaki kapsamsız paket npm'de bir security-holding placeholder'dır; asla kullanılmamalıdır.)
   - `context7` ve `grep_app`: Uzak MCP sunucuları; HEAD isteği ile erişilebilirlik bilgilendirmesi yapar, kurulum gerektirmez.
5. **arcode-opencode-config plugin config** yazımı: `~/.config/opencode/opencode.json` içine aşağıdaki **tarball URL** tuple girdisini ekler/günceller; eski `github:` spec ile yazılmış bir girdi varsa onu da bu tuple ile değiştirir. Diğer ayarları korur; `opencode.jsonc` varsa uyarır.
   ```json
   ["https://github.com/securewanltd/arcode-opencode-config/archive/refs/heads/main.tar.gz",
    { "manifestUrl": "https://raw.githubusercontent.com/securewanltd/arcode-opencode-config/main/manifest.json" }]
   ```
6. **Özet tablo** ve sonraki adımlar (terminal/opencode yeniden başlatma).

**Neden tarball URL?** npm'nin `github:owner/repo` spec'i hedef makinede git kurulu olmasını gerektirir. Sıfır bir kurumsal makinede git olmayabilir ve bu durumda `github:` spec ile plugin sessizce yüklenemez, özel agent'lar hiç çalışmaz. GitHub tarball URL'si (`.tar.gz`) HTTP üzerinden doğrudan indirilebilir, dolayısıyla git olmadan da opencode plugin'i alabilir. Git yine de genel geliştirme iş akışları için kurulur, ancak bu eklenti için zorunlu değildir.

Parametreler:

| Parametre | Varsayılan | Açıklama |
|---|---|---|
| `-Repo` | `securewanltd/arcode-opencode-config` | GitHub repo `owner/name` formatında. |
| `-Branch` | `main` | Git branch/tag/ref. |
| `-SkipMcp` | yok | MCP ön koşul kontrol/kurulumunu atlar. |
| `-SkipOpencode` | yok | opencode CLI kurulumunu atlar. |

Kurulum adımlarını gerçekten çalıştırmadan önce görmek için (dry-run):

```powershell
$env:ARCODE_INSTALL_DRYRUN = '1'
.\bootstrap.ps1
```

Dry-run modunda `npm install`, `winget install` ve `codegraph` installer'ı gerçekten çalıştırılmaz; yerine `DRY RUN: would run ...` mesajları yazdırılır.

## Hafif Kurulum — Mevcut opencode/MCP Ortamı İçin (Windows)

opencode ve MCP araçları zaten kuruluysa sadece plugin config'i yazmak için `install.ps1` kullanın. Varsayılan repo `securewanltd/arcode-opencode-config`'tir.

```powershell
.\install.ps1
```

Farklı bir repo kullanmak için:

```powershell
.\install.ps1 -Repo "fork-owner/arcode-opencode-config" -Branch "main"
```

`install.ps1` yalnızca plugin config yazar ve eksik MCP araçları için elle kurulum talimatı verir. Script adımları şunlardır:

1. `~/.config/opencode/` dizinini oluşturur (yoksa).
2. Mevcut `opencode.json` dosyasını okur; yoksa yeni bir tane oluşturur.
3. Aşağıdaki gibi bir plugin girdisi ekler veya günceller:
   ```json
   ["https://github.com/securewanltd/arcode-opencode-config/archive/refs/heads/main.tar.gz",
    { "manifestUrl": "https://raw.githubusercontent.com/securewanltd/arcode-opencode-config/main/manifest.json" }]
   ```
4. Diğer plugin girdilerini ve tüm üst düzey yapılandırma anahtarlarını korur.
5. Aynı dizinde `opencode.jsonc` varsa uyarı verir ve elle birleştirilmesi gerektiğini söyler.
6. **Otomatik MCP ön koşul kontrolü/kurulumu** yapar (`-SkipMcp` ile devre dışı bırakılabilir):
   - `npm` PATH üzerinde aranır; bulunamazsa uyarı verilir ve devam edilir.
   - Eksik `@theupsider/lsp-mcp@1.3.2` ve `websearch-mcp` npm global paketleri otomatik kurulur. (npm'deki kapsamsız `lsp-mcp` paketi bir placeholder'dır, kullanılmamalıdır.)
   - `codegraph.cmd` PATH üzerinde aranır; bulunamazsa elle kurulması gerektiği uyarısı verilir (script tarafından otomatik kurulmaz).
   - Her araç için son durum tablosu yazdırılır.

MCP kurulumunu atlamak için:

```powershell
.\install.ps1 -SkipMcp
```

Sonrasında:

1. **opencode'i yeniden başlatın.** Açılışta plugin GitHub'dan manifesti çeker; agent'lar, MCP sunucuları ve `config` anahtarları otomatik olarak yüklenir.
2. GitHub'daki `manifest.json` dosyası düzenlendiğinde, her makinedeki bir sonraki opencode başlatışında yeni ayarlar uygulanır.

## MCP Ön Koşulları

### `bootstrap.ps1` (önerilen — sıfır makine)

`bootstrap.ps1` yerel MCP ön koşullarının çoğunu otomatik olarak kurar. Ayrıca **git**'i de kurar (veya eksikse uyarı verir): bu eklenti tarball URL kullandığı için git zorunlu değildir, ancak diğer `github:` spec plugin'ler git gerektirebilir.

- **Node.js / npm**: Eksikse `winget install OpenJS.NodeJS.LTS` ile kurulur.
- **git**: Eksikse `winget install Git.Git` ile kurulur; tarball URL kullanıldığından bu eklenti için zorunlu değildir, başarısızlık durumunda uyarı verilir ve devam edilir.
- `@theupsider/lsp-mcp@1.3.2` / `websearch-mcp`: PATH'te aranır; eksiklerse `npm install -g @theupsider/lsp-mcp@1.3.2 websearch-mcp` çalıştırılır. npm'deki kapsamsız `lsp-mcp` paketi bir security-holding placeholder'dır ve **asla** kullanılmamalıdır.
- `codegraph`: Resmi PowerShell installer'ı (`irm https://raw.githubusercontent.com/colbymchenry/codegraph/main/install.ps1 | iex`) ile kurulur. Installer USER PATH'e ekler; script mevcut oturum PATH'ine `$env:LOCALAPPDATA\codegraph\current\bin` dizinini prepend eder.
- `context7` / `grep_app`: Uzak MCP sunucuları; kurulum gerektirmez. Script, 5 saniyelik HEAD isteği ile erişilebilirliklerini bilgilendirme amaçlı kontrol eder.

### `install.ps1` (hafif kurulum — mevcut ortam)

`install.ps1` yalnızca kontrol eder, elle kurulum için yönlendirir:

- `@theupsider/lsp-mcp@1.3.2` ve `websearch-mcp`: Script, bunları PATH üzerinde arar; eksiklerse `npm install -g @theupsider/lsp-mcp@1.3.2 websearch-mcp` çalıştırır. npm'deki kapsamsız `lsp-mcp` paketi bir placeholder'dır; kullanılmamalıdır.
- `codegraph`: Script sadece `codegraph.cmd`'nin PATH üzerinde olup olmadığını kontrol eder. Eksikse elle kurmanız gerekir; kurulumdan sonra opencode'i yeniden başlatın. (codegraph resmi dağıtımını kullanın; kuruluşunuzun onaylı dağıtım yöntemini tercih edin.)

Uzak MCP sunucuları (`grep_app`, `context7`) için ek yerel kurulum gerekmez.

> **Bilinen sorun: eski `lsp-mcp` placeholder paketi.** Daha önce bare `lsp-mcp` (npm'deki security-holding placeholder) kurulduysa, aynı bin adını (`lsp-mcp`) kullandığı için `@theupsider/lsp-mcp@1.3.2` kurulumu `EEXIST` ile çökebilir. Her iki script de kurulum öncesinde otomatik olarak: (1) çalışan `opencode.exe`/`node.exe` süreçlerini tespit edip MCP kurulumunu atlar (`Kurulumdan önce opencode'u kapatın`), (2) global `lsp-mcp` placeholder paketini, eski shim'leri ve `node_modules\lsp-mcp` dizinini temizler. opencode çalışırken MCP kurulumu yapmayın; dosya kilitleri `EPERM` hatasına yol açar.

> **Not:** Otomatik kurulumları gerçekten çalıştırmadan önce görmek için hem `bootstrap.ps1` hem de `install.ps1` ile `ARCODE_INSTALL_DRYRUN=1` ortam değişkeni kullanılabilir. Bu modda `npm install`, `winget install` ve `codegraph` installer'ı gerçekten çalıştırılmaz, yerine "DRY RUN: would run ..." mesajları yazdırılır.

## Eklenti Seçenekleri

| Seçenek | Tür | Zorunlu | Varsayılan | Açıklama |
|---|---|---|---|---|
| `manifestUrl` | `string` | Evet | — | Manifest JSON dosyasının tam URL'si. Örn: `https://raw.githubusercontent.com/securewanltd/arcode-opencode-config/main/manifest.json` |
| `token` | `string` | Hayır | `process.env.GITHUB_TOKEN` | Private repo'lar için GitHub token. Belirtilmezse `GITHUB_TOKEN` ortam değişkenine bakılır. |
| `timeoutMs` | `number` | Hayır | `5000` | Manifest fetch işlemi için milisaniye cinsinden zaman aşımı. |
| `cacheDir` | `string` | Hayır | `~/.cache/arcode-opencode-config` | Son başarılı manifestin yazılacağı önbellek dizini. |

## Manifest Formatı

`manifest.schema.json` dosyası resmi şemadır. Minimal örnek:

```json
{
  "version": 1,
  "config": {
    "default_agent": "Peganet - Big Boss"
  },
  "agents": {
    "reviewer": {
      "description": "Kod gözden geçiricisi",
      "mode": "subagent",
      "model": "anthropic/claude-sonnet-4",
      "prompt": "Sen deneyimli bir kod gözden geçiricisisin...",
      "temperature": 0.2,
      "permission": { "edit": "deny" }
    }
  },
  "mcp": {
    "github": {
      "type": "remote",
      "url": "https://api.github.com/mcp",
      "enabled": true
    }
  }
}
```

- `version`: Şema sürümü; mevcut revizyon için `1` olmalıdır.
- `config`: İsteğe bağlı. İçindeki değerler `cfg` objesinin üst düzey anahtarlarına birleştirilir. Yalnızca şu anahtarlara izin verilir: `default_agent`, `model`, `small_model`, `share`, `autoupdate`, `instructions`. İzin verilmeyen anahtarlar uyarıyla atlanır.
- `agents`: İsteğe bağlı. Her agent bir obje olmalıdır; bozuk kayıtlar uyarıyla atlanır.
- `mcp`: İsteğe bağlı. Her MCP tanımı bir obje olmalıdır; bozuk kayıtlar atlanır.

Tam örnek için `manifest.example.json` dosyasına bakın.

## Güncelleme Akışı

1. Yönetici GitHub'daki `manifest.json` dosyasını düzenler (örneğin yeni bir agent ekler, model sürümünü değiştirir veya `config.default_agent` günceller).
2. Değişiklik commit/push edilir.
3. Kullanıcı bir sonraki opencode başlatışında arcode-opencode-config eklentisi yeni manifesti çeker.
4. Yeni `agents`, `mcp` ve `config` tanımları canlı `cfg` objesine enjekte edilir.

> **Not:** opencode `config` hook'unu yalnızca başlangıçta bir kez çağırır; çalışan bir oturumda yapılan değişiklikler anında yansımaz. GitHub'daki `manifest.json` düzenlemesi, her makinedeki bir sonraki opencode başlatışında otomatik olarak uygulanır. Yeni ayarları almak için opencode yeniden başlatılmalıdır.

## Önbellek ve Geri Dönüş (Fallback)

arcode-opencode-config her zaman aşağıdaki sırayı izler:

1. **Fetch:** `manifestUrl` adresine zaman aşımı dahilinde HTTP isteği atar.
2. **Başarı:** Ham JSON metni `cacheDir/manifest.json` dosyasına yazılır ve yapılandırmaya enjekte edilir.
3. **Herhangi Bir Hata:** Ağ hatası, HTTP 4xx/5xx, JSON parse hatası veya zaman aşımı durumlarında eklenti `cacheDir/manifest.json` dosyasını okumaya çalışır.
4. **Önbellek Var:** Eski manifest önbellekten alınır ve yapılandırmaya enjekte edilir.
5. **Önbellek Yok:** Bir uyarı kaydedilir ve mevcut yapılandırma dokunulmadan bırakılır. opencode normal şekilde başlamaya devam eder.

Eklentinin `config` hook'u asla dışarı fırlatılmayan bir hataya neden olmaz; tüm hatalar yakalanır ve günlüğe yazılır.

## Güvenlik Notları

- **Manifest referansını sabitleyin:** `manifest.json` URL'sinde dal adı yerine `main`/`master` kullanıyorsanız, beklenmedik değişikliklere karşı commit SHA'sı veya etiket (tag) ile sabitlemeyi düşünün. Örnek: `.../refs/tags/v1.2.3/manifest.json`
- **Manifest reposunu koruyun:** Manifest dosyası agent sistem prompt'ları ve MCP sunucu adresleri gibi hassas yapılandırmalar içerebilir. Repo yazma erişimini sınırlayın ve branch protection kuralları uygulayın.
- **Token yönetimi:** `token` seçeneğini düz metin olarak opencode.json dosyasına yazmak yerine mümkünse `GITHUB_TOKEN` ortam değişkenini kullanın. GPO/Intune ile ortam değişkeni dağıtmak daha güvenlidir.
- **Token kapsamı:** Private manifest için yalnızca `contents:read` kapsamına sahip klasik veya fine-grained bir token kullanın.
- **MCP sunucuları:** Remote MCP sunucuları için `headers` alanına API anahtarı yazıyorsanız, bu anahtarların kullanıcı makinelerine ulaşacağını unutmayın. Hassas anahtarlar için kuruluş içi bir secret yönetim çözümü değerlendirin.

## Geliştirme

```bash
npm install
npm run build
npm test
```

Kod `src/` dizininde TypeScript ile yazılır, `tsc` ile `dist/` dizinine ES modülü olarak derlenir. `@opencode-ai/plugin` paketine ait resmi tipler mevcut olmadığında yerel olarak `src/types.ts` içindeki minimal tipler kullanılır.

## Lisans

MIT
