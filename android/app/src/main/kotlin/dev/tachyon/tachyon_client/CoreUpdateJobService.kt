package dev.tachyon.tachyon_client

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** Android сохраняет задание, даже если экран приложения закрыт. */
class CoreUpdateJobService : JobService() {
    private val executor = Executors.newSingleThreadExecutor()
    private val tokens = java.util.concurrent.ConcurrentHashMap<Int, CoreUpdateToken>()
    private val main = Handler(Looper.getMainLooper())

    override fun onStartJob(params: JobParameters): Boolean {
        val token = CoreUpdateToken()
        tokens[params.jobId] = token
        executor.execute {
            val completed = CoreUpdater.update(applicationContext, token)
            main.post {
                if (tokens.remove(params.jobId, token)) jobFinished(params, token.cancelled || completed == null)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters): Boolean {
        tokens.remove(params.jobId)?.cancel()
        return true
    }

    override fun onDestroy() {
        tokens.values.forEach { it.cancel() }
        executor.shutdown()
        super.onDestroy()
    }

    companion object {
        const val MANUAL = 3401
        const val AUTOMATIC = 3402
        private fun scheduler(context: Context) = context.getSystemService(JobScheduler::class.java)
        fun pending(context: Context): Boolean = scheduler(context).allPendingJobs.any { it.id == MANUAL || it.id == AUTOMATIC && !it.isPeriodic }
        private fun builder(context: Context, id: Int) = JobInfo.Builder(id, ComponentName(context, CoreUpdateJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPersisted(true)
            .setBackoffCriteria(TimeUnit.SECONDS.toMillis(30), JobInfo.BACKOFF_POLICY_EXPONENTIAL)

        fun enqueue(context: Context) {
            if ((CoreUpdater.snapshot(context)["busy"] as? Boolean) == true) return
            CoreUpdater.status(context, "queued", "Ожидание сети и запуска фонового задания")
            check(scheduler(context).schedule(builder(context, MANUAL).build()) == JobScheduler.RESULT_SUCCESS) { "Android не смог запланировать обновление." }
        }

        fun configureAuto(context: Context, enabled: Boolean) {
            if (enabled) {
                check(scheduler(context).schedule(builder(context, AUTOMATIC)
                    .setPeriodic(TimeUnit.HOURS.toMillis(24), TimeUnit.HOURS.toMillis(2))
                    .setRequiresBatteryNotLow(true).build()) == JobScheduler.RESULT_SUCCESS) { "Android не смог включить автообновление." }
            } else scheduler(context).cancel(AUTOMATIC)
            CoreStore.setAutoUpdate(context, enabled)
            if (enabled) enqueue(context)
        }
    }
}
