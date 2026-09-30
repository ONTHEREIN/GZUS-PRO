package cn.gzus.pro

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetRefreshTransactionsTest {
    @Test
    fun lateSuccessAndUnauthorizedResponsesCannotModifyReplacedSession() {
        val generation = AtomicReference<String?>("old-request")
        val snapshot = AtomicReference("old-account")
        val responseReady = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val lateResponses = executor.submit {
                assertTrue(responseReady.await(5, TimeUnit.SECONDS))
                assertFalse(WidgetRefreshTransactions.commit("old-request", generation::get) {
                    snapshot.set("late-old-account")
                })
                assertFalse(WidgetRefreshTransactions.commit("old-request", generation::get) {
                    generation.set(null)
                    snapshot.set("")
                })
            }
            WidgetRefreshTransactions.update {
                generation.set("new-request")
                snapshot.set("new-account")
            }
            responseReady.countDown()
            lateResponses.get(5, TimeUnit.SECONDS)
            assertEquals("new-request", generation.get())
            assertEquals("new-account", snapshot.get())
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun logoutWaitsForAnAcceptedCommitAndRemovesItsData() {
        val generation = AtomicReference<String?>("current-request")
        val snapshot = AtomicReference("current-account")
        val commitEntered = CountDownLatch(1)
        val logoutAttempted = CountDownLatch(1)
        val executor = Executors.newSingleThreadExecutor()
        try {
            val logout = executor.submit {
                assertTrue(commitEntered.await(5, TimeUnit.SECONDS))
                logoutAttempted.countDown()
                WidgetRefreshTransactions.update {
                    generation.set(null)
                    snapshot.set("")
                }
            }
            assertTrue(WidgetRefreshTransactions.commit("current-request", generation::get) {
                commitEntered.countDown()
                assertTrue(logoutAttempted.await(5, TimeUnit.SECONDS))
                snapshot.set("accepted-response")
            })
            logout.get(5, TimeUnit.SECONDS)
            assertEquals(null, generation.get())
            assertEquals("", snapshot.get())
            assertFalse(WidgetRefreshTransactions.commit("current-request", generation::get) {
                snapshot.set("late-response")
            })
        } finally {
            executor.shutdownNow()
        }
    }

    @Test
    fun sameAccountReconfigurationInvalidatesEarlierRequest() {
        val generation = AtomicReference<String?>("first-visit")
        val snapshot = AtomicReference("before-adjustment")
        WidgetRefreshTransactions.update {
            generation.set("second-visit")
            snapshot.set("after-adjustment")
        }
        assertFalse(WidgetRefreshTransactions.commit("first-visit", generation::get) {
            snapshot.set("before-adjustment")
        })
        assertEquals("after-adjustment", snapshot.get())
    }
}
