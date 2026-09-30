package cn.gzus.pro

/** 串行化组件配置和快照存储；网络请求不能占用此锁。 */
internal object WidgetRefreshTransactions {
    private val lock = Any()

    fun <T> update(persist: () -> T): T = synchronized(lock) { persist() }

    fun commit(
        requestedGeneration: String,
        currentGeneration: () -> String?,
        persist: () -> Unit,
    ): Boolean = synchronized(lock) {
        if (requestedGeneration != currentGeneration()) return@synchronized false
        persist()
        true
    }
}
