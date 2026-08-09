/*
Copyright (C) 2023-2026 QuantumNous

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU Affero General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
GNU Affero General Public License for more details.

You should have received a copy of the GNU Affero General Public License
along with this program. If not, see <https://www.gnu.org/licenses/>.

For commercial licensing, please contact support@quantumnous.com
*/
import fs from 'node:fs/promises'
import path from 'node:path'

const LOCALES_DIR = path.resolve('src/i18n/locales')

const en = {
  'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / TOKEN SERVICE',
  Breadcrumb: 'Breadcrumb',
  'Build in public. Earn access.': 'Build in public. Earn access.',
  Carousel: 'Carousel',
  'Creem Product ID': 'Creem Product ID',
  Decrement: 'Decrement',
  'Delete row': 'Delete row',
  Diff: 'Diff',
  Field: 'Field',
  'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.',
  'Goroutines:': 'Goroutines:',
  'Group Type': 'Group Type',
  Increment: 'Increment',
  'LIVE CONTRIBUTIONS': 'LIVE CONTRIBUTIONS',
  'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / OPEN-SOURCE BOUNTY FIELD',
  'Local Value': 'Local Value',
  MERGED: 'MERGED',
  'Metered feature': 'Metered feature',
  'Model Group': 'Model Group',
  'More pages': 'More pages',
  'Next slide': 'Next slide',
  'No description provided': 'No description provided',
  'No endpoint mappings configured.': 'No endpoint mappings configured.',
  'No items configured yet.': 'No items configured yet.',
  'Open-source bounty delivery field': 'Open-source bounty delivery field',
  Optional: 'Optional',
  Pagination: 'Pagination',
  'Please retry or refresh the page.': 'Please retry or refresh the page.',
  'Prefill group created': 'Prefill group created',
  'Prefill group updated': 'Prefill group updated',
  'Previous slide': 'Previous slide',
  'Remove tag': 'Remove tag',
  'Scroll to bottom': 'Scroll to bottom',
  'Select {{label}}': 'Select {{label}}',
  Slide: 'Slide',
  'Stripe Price ID': 'Stripe Price ID',
  'Tag Group': 'Tag Group',
  'Theme options': 'Theme options',
  'Toggle Sidebar': 'Toggle Sidebar',
  'Toggle password visibility': 'Toggle password visibility',
  'Upstream Value': 'Upstream Value',
  'Verified open-source work becomes usable model access.':
    'Verified open-source work becomes usable model access.',
  'View diff': 'View diff',
  'Waffo Pancake Product ID': 'Waffo Pancake Product ID',
  'stable access layer': 'stable access layer',
  'min outage': 'min outage',
  '{{count}} API entries deleted. Click "Save Settings" to apply.':
    '{{count}} API entries deleted. Click "Save Settings" to apply.',
  '{{count}} FAQs deleted. Click "Save Settings" to apply.':
    '{{count}} FAQs deleted. Click "Save Settings" to apply.',
  '{{count}} announcements deleted. Click "Save Settings" to apply.':
    '{{count}} announcements deleted. Click "Save Settings" to apply.',
  '{{count}} channels': '{{count}} channels',
  '{{count}} group': '{{count}} group',
  '{{count}} groups': '{{count}} groups',
  '{{count}} groups deleted. Click "Save Settings" to apply.':
    '{{count}} groups deleted. Click "Save Settings" to apply.',
  '{{count}} item': '{{count}} item',
  '{{count}} items': '{{count}} items',
  '{{count}} model(s)': '{{count}} model(s)',
  '{{label}} option preview': '{{label}} option preview',
  'Reusable sets of models you can attach to channels.':
    'Reusable sets of models you can attach to channels.',
  'Collections of metadata tags for bulk operations.':
    'Collections of metadata tags for bulk operations.',
  'HTTP endpoint mappings shared across providers.':
    'HTTP endpoint mappings shared across providers.',
  'Endpoint Group': 'Endpoint Group',
}

const translations = {
  zh: {
    Breadcrumb: '面包屑',
    'Build in public. Earn access.': '公开构建，赚取访问权限。',
    Carousel: '轮播',
    'Creem Product ID': 'Creem 产品 ID',
    Decrement: '减少',
    'Delete row': '删除行',
    Diff: '差异',
    Field: '字段',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      '已资助的悬赏、补丁、评审证据和已验证合并将连接到稳定的令牌服务。',
    'Goroutines:': 'Goroutine 数：',
    'Group Type': '分组类型',
    Increment: '增加',
    'LIVE CONTRIBUTIONS': '实时贡献',
    'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / 开源悬赏场',
    'Local Value': '本地值',
    MERGED: '已合并',
    'Metered feature': '计量功能',
    'Model Group': '模型分组',
    'More pages': '更多页面',
    'Next slide': '下一张幻灯片',
    'No description provided': '未提供描述',
    'No endpoint mappings configured.': '未配置端点映射。',
    'No items configured yet.': '尚未配置项目。',
    'Open-source bounty delivery field': '开源悬赏交付场',
    Optional: '可选',
    Pagination: '分页',
    'Please retry or refresh the page.': '请重试或刷新页面。',
    'Prefill group created': '预填充分组已创建',
    'Prefill group updated': '预填充分组已更新',
    'Previous slide': '上一张幻灯片',
    'Remove tag': '移除标签',
    'Scroll to bottom': '滚动到底部',
    'Select {{label}}': '选择{{label}}',
    Slide: '幻灯片',
    'Stripe Price ID': 'Stripe 价格 ID',
    'Tag Group': '标签分组',
    'Theme options': '主题选项',
    'Toggle Sidebar': '切换侧边栏',
    'Toggle password visibility': '切换密码可见性',
    'Upstream Value': '上游值',
    'Verified open-source work becomes usable model access.':
      '经验证的开源工作可兑换为可用的模型访问权限。',
    'View diff': '查看差异',
    'Waffo Pancake Product ID': 'Waffo Pancake 产品 ID',
    'stable access layer': '稳定访问层',
    'min outage': '最短中断',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      '已删除 {{count}} 个 API 条目。点击“保存设置”应用。',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      '已删除 {{count}} 个 FAQ。点击“保存设置”应用。',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      '已删除 {{count}} 条公告。点击“保存设置”应用。',
    '{{count}} channels': '{{count}} 个渠道',
    '{{count}} group': '{{count}} 个分组',
    '{{count}} groups': '{{count}} 个分组',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      '已删除 {{count}} 个分组。点击“保存设置”应用。',
    '{{count}} item': '{{count}} 项',
    '{{count}} items': '{{count}} 项',
    '{{count}} model(s)': '{{count}} 个模型',
    '{{label}} option preview': '{{label}} 选项预览',
    'Reusable sets of models you can attach to channels.':
      '可复用的模型集合，可附加到渠道。',
    'Collections of metadata tags for bulk operations.':
      '用于批量操作的元数据标签集合。',
    'HTTP endpoint mappings shared across providers.':
      '各提供商共享的 HTTP 端点映射。',
    'Endpoint Group': '端点分组',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / 令牌服务',
  },
  'zh-TW': {
    Breadcrumb: '麵包屑',
    'Build in public. Earn access.': '公開建置，賺取存取權限。',
    Carousel: '輪播',
    'Creem Product ID': 'Creem 產品 ID',
    Decrement: '減少',
    'Delete row': '刪除列',
    Diff: '差異',
    Field: '欄位',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      '已資助的懸賞、修補程式、審查證據與已驗證合併會連接至穩定的權杖服務。',
    'Goroutines:': 'Goroutine 數：',
    'Group Type': '群組類型',
    Increment: '增加',
    'LIVE CONTRIBUTIONS': '即時貢獻',
    'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / 開源懸賞場',
    'Local Value': '本機值',
    MERGED: '已合併',
    'Metered feature': '計量功能',
    'Model Group': '模型群組',
    'More pages': '更多頁面',
    'Next slide': '下一張投影片',
    'No description provided': '未提供描述',
    'No endpoint mappings configured.': '尚未設定端點對應。',
    'No items configured yet.': '尚未設定項目。',
    'Open-source bounty delivery field': '開源懸賞交付場',
    Optional: '選填',
    Pagination: '分頁',
    'Please retry or refresh the page.': '請重試或重新整理頁面。',
    'Prefill group created': '預填群組已建立',
    'Prefill group updated': '預填群組已更新',
    'Previous slide': '上一張投影片',
    'Remove tag': '移除標籤',
    'Scroll to bottom': '捲動到底部',
    'Select {{label}}': '選取{{label}}',
    Slide: '投影片',
    'Stripe Price ID': 'Stripe 價格 ID',
    'Tag Group': '標籤群組',
    'Theme options': '佈景主題選項',
    'Toggle Sidebar': '切換側邊欄',
    'Toggle password visibility': '切換密碼可見性',
    'Upstream Value': '上游值',
    'Verified open-source work becomes usable model access.':
      '經驗證的開源工作可兌換為可用的模型存取權限。',
    'View diff': '檢視差異',
    'Waffo Pancake Product ID': 'Waffo Pancake 產品 ID',
    'stable access layer': '穩定存取層',
    'min outage': '最短中斷',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      '已刪除 {{count}} 個 API 項目。按一下「儲存設定」套用。',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      '已刪除 {{count}} 個 FAQ。按一下「儲存設定」套用。',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      '已刪除 {{count}} 則公告。按一下「儲存設定」套用。',
    '{{count}} channels': '{{count}} 個頻道',
    '{{count}} group': '{{count}} 個群組',
    '{{count}} groups': '{{count}} 個群組',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      '已刪除 {{count}} 個群組。按一下「儲存設定」套用。',
    '{{count}} item': '{{count}} 個項目',
    '{{count}} items': '{{count}} 個項目',
    '{{count}} model(s)': '{{count}} 個模型',
    '{{label}} option preview': '{{label}} 選項預覽',
    'Reusable sets of models you can attach to channels.':
      '可重複使用、可附加至頻道的模型集合。',
    'Collections of metadata tags for bulk operations.':
      '用於批次操作的中繼資料標籤集合。',
    'HTTP endpoint mappings shared across providers.':
      '各提供者共用的 HTTP 端點對應。',
    'Endpoint Group': '端點群組',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / 權杖服務',
  },
  fr: {
    Breadcrumb: 'Fil d’Ariane',
    'Build in public. Earn access.':
      'Construisez au grand jour. Gagnez l’accès.',
    Carousel: 'Carrousel',
    'Creem Product ID': 'ID produit Creem',
    Decrement: 'Diminuer',
    'Delete row': 'Supprimer la ligne',
    Diff: 'Différence',
    Field: 'Champ',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      'Les primes financées, correctifs, preuves de revue et fusions vérifiées se connectent à un service de jetons stable.',
    'Goroutines:': 'Goroutines :',
    'Group Type': 'Type de groupe',
    Increment: 'Augmenter',
    'LIVE CONTRIBUTIONS': 'CONTRIBUTIONS EN DIRECT',
    'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / CHAMP DES PRIMES OPEN SOURCE',
    'Local Value': 'Valeur locale',
    MERGED: 'FUSIONNÉ',
    'Metered feature': 'Fonctionnalité mesurée',
    'Model Group': 'Groupe de modèles',
    'More pages': 'Plus de pages',
    'Next slide': 'Diapositive suivante',
    'No description provided': 'Aucune description fournie',
    'No endpoint mappings configured.':
      'Aucun mappage de point de terminaison configuré.',
    'No items configured yet.': 'Aucun élément configuré pour le moment.',
    'Open-source bounty delivery field':
      'Champ de livraison des primes open source',
    Optional: 'Facultatif',
    Pagination: 'Pagination',
    'Please retry or refresh the page.': 'Réessayez ou actualisez la page.',
    'Prefill group created': 'Groupe de préremplissage créé',
    'Prefill group updated': 'Groupe de préremplissage mis à jour',
    'Previous slide': 'Diapositive précédente',
    'Remove tag': 'Supprimer le tag',
    'Scroll to bottom': 'Faire défiler jusqu’en bas',
    'Select {{label}}': 'Sélectionner {{label}}',
    Slide: 'Diapositive',
    'Stripe Price ID': 'ID de prix Stripe',
    'Tag Group': 'Groupe de tags',
    'Theme options': 'Options du thème',
    'Toggle Sidebar': 'Afficher/masquer la barre latérale',
    'Toggle password visibility': 'Afficher/masquer le mot de passe',
    'Upstream Value': 'Valeur amont',
    'Verified open-source work becomes usable model access.':
      'Le travail open source vérifié devient un accès utilisable aux modèles.',
    'View diff': 'Voir les différences',
    'Waffo Pancake Product ID': 'ID produit Waffo Pancake',
    'stable access layer': 'couche d’accès stable',
    'min outage': 'min d’interruption',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      '{{count}} entrées API supprimées. Cliquez sur « Enregistrer les paramètres » pour appliquer.',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      '{{count}} FAQ supprimées. Cliquez sur « Enregistrer les paramètres » pour appliquer.',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      '{{count}} annonces supprimées. Cliquez sur « Enregistrer les paramètres » pour appliquer.',
    '{{count}} channels': '{{count}} canaux',
    '{{count}} group': '{{count}} groupe',
    '{{count}} groups': '{{count}} groupes',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      '{{count}} groupes supprimés. Cliquez sur « Enregistrer les paramètres » pour appliquer.',
    '{{count}} item': '{{count}} élément',
    '{{count}} items': '{{count}} éléments',
    '{{count}} model(s)': '{{count}} modèle(s)',
    '{{label}} option preview': 'Aperçu de l’option {{label}}',
    'Reusable sets of models you can attach to channels.':
      'Ensembles réutilisables de modèles à associer aux canaux.',
    'Collections of metadata tags for bulk operations.':
      'Collections de tags de métadonnées pour les opérations groupées.',
    'HTTP endpoint mappings shared across providers.':
      'Mappages de points de terminaison HTTP partagés entre fournisseurs.',
    'Endpoint Group': 'Groupe de points de terminaison',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / SERVICE DE JETONS',
  },
  ja: {
    Breadcrumb: 'パンくずリスト',
    'Build in public. Earn access.': '公開で構築し、アクセス権を獲得。',
    Carousel: 'カルーセル',
    'Creem Product ID': 'Creem プロダクト ID',
    Decrement: '減少',
    'Delete row': '行を削除',
    Diff: '差分',
    Field: 'フィールド',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      '資金提供済みのバウンティ、パッチ、レビュー証拠、検証済みマージが安定したトークンサービスにつながります。',
    'Goroutines:': 'Goroutine 数：',
    'Group Type': 'グループ種別',
    Increment: '増加',
    'LIVE CONTRIBUTIONS': 'リアルタイム貢献',
    'LMM / OPEN-SOURCE BOUNTY FIELD':
      'LMM / オープンソースバウンティフィールド',
    'Local Value': 'ローカル値',
    MERGED: 'マージ済み',
    'Metered feature': '従量機能',
    'Model Group': 'モデルグループ',
    'More pages': 'さらにページ',
    'Next slide': '次のスライド',
    'No description provided': '説明はありません',
    'No endpoint mappings configured.':
      'エンドポイントマッピングが設定されていません。',
    'No items configured yet.': '項目はまだ設定されていません。',
    'Open-source bounty delivery field':
      'オープンソースバウンティ配信フィールド',
    Optional: '任意',
    Pagination: 'ページネーション',
    'Please retry or refresh the page.':
      '再試行するか、ページを更新してください。',
    'Prefill group created': 'プレフィルグループを作成しました',
    'Prefill group updated': 'プレフィルグループを更新しました',
    'Previous slide': '前のスライド',
    'Remove tag': 'タグを削除',
    'Scroll to bottom': '下までスクロール',
    'Select {{label}}': '{{label}}を選択',
    Slide: 'スライド',
    'Stripe Price ID': 'Stripe 価格 ID',
    'Tag Group': 'タググループ',
    'Theme options': 'テーマ設定',
    'Toggle Sidebar': 'サイドバーを切り替え',
    'Toggle password visibility': 'パスワード表示を切り替え',
    'Upstream Value': '上流値',
    'Verified open-source work becomes usable model access.':
      '検証済みのオープンソース活動が、利用可能なモデルアクセスになります。',
    'View diff': '差分を表示',
    'Waffo Pancake Product ID': 'Waffo Pancake プロダクト ID',
    'stable access layer': '安定したアクセス層',
    'min outage': '最小停止時間',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      '{{count}} 件の API エントリを削除しました。「設定を保存」をクリックして適用してください。',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      '{{count}} 件の FAQ を削除しました。「設定を保存」をクリックして適用してください。',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      '{{count}} 件のお知らせを削除しました。「設定を保存」をクリックして適用してください。',
    '{{count}} channels': '{{count}} チャンネル',
    '{{count}} group': '{{count}} グループ',
    '{{count}} groups': '{{count}} グループ',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      '{{count}} グループを削除しました。「設定を保存」をクリックして適用してください。',
    '{{count}} item': '{{count}} 項目',
    '{{count}} items': '{{count}} 項目',
    '{{count}} model(s)': '{{count}} モデル',
    '{{label}} option preview': '{{label}} のオプションプレビュー',
    'Reusable sets of models you can attach to channels.':
      'チャンネルに追加できる再利用可能なモデルセット。',
    'Collections of metadata tags for bulk operations.':
      '一括操作用のメタデータタグのコレクション。',
    'HTTP endpoint mappings shared across providers.':
      'プロバイダー間で共有する HTTP エンドポイントマッピング。',
    'Endpoint Group': 'エンドポイントグループ',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / トークンサービス',
  },
  ru: {
    Breadcrumb: 'Хлебные крошки',
    'Build in public. Earn access.': 'Создавайте открыто и получайте доступ.',
    Carousel: 'Карусель',
    'Creem Product ID': 'ID продукта Creem',
    Decrement: 'Уменьшить',
    'Delete row': 'Удалить строку',
    Diff: 'Разница',
    Field: 'Поле',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      'Финансируемые баунти, патчи, доказательства ревью и проверенные слияния подключаются к стабильному сервису токенов.',
    'Goroutines:': 'Горутины:',
    'Group Type': 'Тип группы',
    Increment: 'Увеличить',
    'LIVE CONTRIBUTIONS': 'АКТИВНЫЕ ВКЛАДЫ',
    'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / ПОЛЕ OPEN-SOURCE БАУНТИ',
    'Local Value': 'Локальное значение',
    MERGED: 'ОБЪЕДИНЕНО',
    'Metered feature': 'Тарифицируемая функция',
    'Model Group': 'Группа моделей',
    'More pages': 'Другие страницы',
    'Next slide': 'Следующий слайд',
    'No description provided': 'Описание не указано',
    'No endpoint mappings configured.':
      'Сопоставления конечных точек не настроены.',
    'No items configured yet.': 'Элементы ещё не настроены.',
    'Open-source bounty delivery field': 'Поле поставки open-source баунти',
    Optional: 'Необязательно',
    Pagination: 'Пагинация',
    'Please retry or refresh the page.':
      'Повторите попытку или обновите страницу.',
    'Prefill group created': 'Группа предзаполнения создана',
    'Prefill group updated': 'Группа предзаполнения обновлена',
    'Previous slide': 'Предыдущий слайд',
    'Remove tag': 'Удалить тег',
    'Scroll to bottom': 'Прокрутить вниз',
    'Select {{label}}': 'Выбрать {{label}}',
    Slide: 'Слайд',
    'Stripe Price ID': 'ID цены Stripe',
    'Tag Group': 'Группа тегов',
    'Theme options': 'Параметры темы',
    'Toggle Sidebar': 'Переключить боковую панель',
    'Toggle password visibility': 'Показать или скрыть пароль',
    'Upstream Value': 'Верхнее значение',
    'Verified open-source work becomes usable model access.':
      'Проверенная работа с открытым исходным кодом превращается в доступ к моделям.',
    'View diff': 'Показать различия',
    'Waffo Pancake Product ID': 'ID продукта Waffo Pancake',
    'stable access layer': 'стабильный уровень доступа',
    'min outage': 'мин. простой',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      'Удалено записей API: {{count}}. Нажмите «Сохранить настройки», чтобы применить.',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      'Удалено FAQ: {{count}}. Нажмите «Сохранить настройки», чтобы применить.',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      'Удалено объявлений: {{count}}. Нажмите «Сохранить настройки», чтобы применить.',
    '{{count}} channels': '{{count}} каналов',
    '{{count}} group': '{{count}} группа',
    '{{count}} groups': '{{count}} групп',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      'Удалено групп: {{count}}. Нажмите «Сохранить настройки», чтобы применить.',
    '{{count}} item': '{{count}} элемент',
    '{{count}} items': '{{count}} элементов',
    '{{count}} model(s)': '{{count}} моделей',
    '{{label}} option preview': 'Предпросмотр параметра {{label}}',
    'Reusable sets of models you can attach to channels.':
      'Повторно используемые наборы моделей для подключения к каналам.',
    'Collections of metadata tags for bulk operations.':
      'Коллекции тегов метаданных для пакетных операций.',
    'HTTP endpoint mappings shared across providers.':
      'Сопоставления HTTP-конечных точек, общие для провайдеров.',
    'Endpoint Group': 'Группа конечных точек',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / СЕРВИС ТОКЕНОВ',
  },
  vi: {
    Breadcrumb: 'Breadcrumb',
    'Build in public. Earn access.': 'Xây dựng công khai. Nhận quyền truy cập.',
    Carousel: 'Băng chuyền',
    'Creem Product ID': 'ID sản phẩm Creem',
    Decrement: 'Giảm',
    'Delete row': 'Xóa hàng',
    Diff: 'Khác biệt',
    Field: 'Trường',
    'Funded bounties, patches, review evidence, and verified merges connect to a stable token service.':
      'Tiền thưởng, bản vá, bằng chứng đánh giá và các lần hợp nhất đã xác minh kết nối với dịch vụ token ổn định.',
    'Goroutines:': 'Goroutine:',
    'Group Type': 'Loại nhóm',
    Increment: 'Tăng',
    'LIVE CONTRIBUTIONS': 'ĐÓNG GÓP TRỰC TIẾP',
    'LMM / OPEN-SOURCE BOUNTY FIELD': 'LMM / TRƯỜNG TIỀN THƯỞNG MÃ NGUỒN MỞ',
    'Local Value': 'Giá trị cục bộ',
    MERGED: 'ĐÃ HỢP NHẤT',
    'Metered feature': 'Tính năng tính phí theo mức dùng',
    'Model Group': 'Nhóm mô hình',
    'More pages': 'Thêm trang',
    'Next slide': 'Trang chiếu tiếp theo',
    'No description provided': 'Chưa cung cấp mô tả',
    'No endpoint mappings configured.': 'Chưa cấu hình ánh xạ endpoint.',
    'No items configured yet.': 'Chưa cấu hình mục nào.',
    'Open-source bounty delivery field':
      'Trường phân phối tiền thưởng mã nguồn mở',
    Optional: 'Tùy chọn',
    Pagination: 'Phân trang',
    'Please retry or refresh the page.': 'Vui lòng thử lại hoặc làm mới trang.',
    'Prefill group created': 'Đã tạo nhóm điền sẵn',
    'Prefill group updated': 'Đã cập nhật nhóm điền sẵn',
    'Previous slide': 'Trang chiếu trước',
    'Remove tag': 'Xóa thẻ',
    'Scroll to bottom': 'Cuộn xuống cuối',
    'Select {{label}}': 'Chọn {{label}}',
    Slide: 'Trang chiếu',
    'Stripe Price ID': 'ID giá Stripe',
    'Tag Group': 'Nhóm thẻ',
    'Theme options': 'Tùy chọn giao diện',
    'Toggle Sidebar': 'Bật/tắt thanh bên',
    'Toggle password visibility': 'Bật/tắt hiển thị mật khẩu',
    'Upstream Value': 'Giá trị upstream',
    'Verified open-source work becomes usable model access.':
      'Công việc mã nguồn mở đã xác minh trở thành quyền truy cập mô hình có thể sử dụng.',
    'View diff': 'Xem khác biệt',
    'Waffo Pancake Product ID': 'ID sản phẩm Waffo Pancake',
    'stable access layer': 'lớp truy cập ổn định',
    'min outage': 'phút gián đoạn',
    '{{count}} API entries deleted. Click "Save Settings" to apply.':
      'Đã xóa {{count}} mục API. Nhấp “Lưu cài đặt” để áp dụng.',
    '{{count}} FAQs deleted. Click "Save Settings" to apply.':
      'Đã xóa {{count}} FAQ. Nhấp “Lưu cài đặt” để áp dụng.',
    '{{count}} announcements deleted. Click "Save Settings" to apply.':
      'Đã xóa {{count}} thông báo. Nhấp “Lưu cài đặt” để áp dụng.',
    '{{count}} channels': '{{count}} kênh',
    '{{count}} group': '{{count}} nhóm',
    '{{count}} groups': '{{count}} nhóm',
    '{{count}} groups deleted. Click "Save Settings" to apply.':
      'Đã xóa {{count}} nhóm. Nhấp “Lưu cài đặt” để áp dụng.',
    '{{count}} item': '{{count}} mục',
    '{{count}} items': '{{count}} mục',
    '{{count}} model(s)': '{{count}} mô hình',
    '{{label}} option preview': 'Xem trước tùy chọn {{label}}',
    'Reusable sets of models you can attach to channels.':
      'Các bộ mô hình có thể dùng lại và gắn vào kênh.',
    'Collections of metadata tags for bulk operations.':
      'Tập hợp thẻ siêu dữ liệu cho thao tác hàng loạt.',
    'HTTP endpoint mappings shared across providers.':
      'Ánh xạ endpoint HTTP dùng chung giữa các nhà cung cấp.',
    'Endpoint Group': 'Nhóm endpoint',
    'API.LMM.BEST / TOKEN SERVICE': 'API.LMM.BEST / DỊCH VỤ TOKEN',
  },
}

const locales = ['en', 'zh', 'zh-TW', 'fr', 'ja', 'ru', 'vi']

for (const locale of locales) {
  const file = path.join(LOCALES_DIR, `${locale}.json`)
  const json = JSON.parse(await fs.readFile(file, 'utf8'))
  const translation = json.translation ?? (json.translation = {})
  const values = { ...en, ...(translations[locale] ?? {}) }
  let added = 0

  for (const [key, value] of Object.entries(values)) {
    if (!Object.hasOwn(translation, key)) {
      translation[key] = value
      added += 1
    }
  }

  await fs.writeFile(file, `${JSON.stringify(json, null, 2)}\n`, 'utf8')
  console.log(`${locale}: added ${added} keys`)
}
