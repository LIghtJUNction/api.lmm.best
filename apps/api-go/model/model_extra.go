package model

func GetModelEnableGroups(modelName string) []string {
	if modelName == "" {
		return make([]string, 0)
	}
	snapshot := loadPricingSnapshot()
	if snapshot == nil {
		GetPricing()
		snapshot = pricingCache.Load()
	} else if pricingCacheNeedsRefresh(snapshot) {
		startPricingRefresh()
	}
	if snapshot == nil {
		return make([]string, 0)
	}
	groups, ok := snapshot.modelEnableGroups[modelName]
	if !ok {
		return make([]string, 0)
	}
	return append([]string(nil), groups...)
}

// GetModelQuotaTypes 返回指定模型的计费类型集合（来自缓存）
func GetModelQuotaTypes(modelName string) []int {
	snapshot := loadPricingSnapshot()
	if snapshot == nil {
		GetPricing()
		snapshot = pricingCache.Load()
	} else if pricingCacheNeedsRefresh(snapshot) {
		startPricingRefresh()
	}
	if snapshot == nil {
		return []int{}
	}
	quota, ok := snapshot.modelQuotaTypes[modelName]
	if !ok {
		return []int{}
	}
	return []int{quota}
}
