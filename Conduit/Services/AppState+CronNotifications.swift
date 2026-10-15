//
//  AppState+CronNotifications.swift
//  Conduit
//
//  Per-job cron notifications: the Cron tab's "Notify me" switch, kept by
//  the host's notifier plugin so its turn-end hooks skip a muted job's push.
//

import Foundation
import OSLog

private let cronNotificationsLogger = Logger(subsystem: "com.milim.relay", category: "CronNotifications")

extension AppState {
    /// Whether the host's notifier plugin keeps per-job cron notifications.
    var supportsCronNotifications: Bool {
        notifierPlugin.reports(CronNotificationsClient.capability)
    }

    private func cronNotificationsKey(profile: String) -> String {
        (activeDashboardID?.uuidString ?? "") + "|" + profile
    }

    /// Whether a job's runs notify on the active dashboard and profile.
    /// Unknown (not read yet) counts as on, as the host defaults.
    func cronJobNotifies(_ job: CronJob) -> Bool {
        guard cronMutedJobsKey == cronNotificationsKey(profile: activeProfile) else { return true }
        return !cronMutedJobIDs.contains(job.id)
    }

    func refreshCronNotifications() async {
        guard supportsCronNotifications else { return }
        let profile = activeProfile
        let key = cronNotificationsKey(profile: profile)
        do {
            let muted = try await cronNotificationsClient.muted(profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile) else { return }
            cronMutedJobIDs = muted
            cronMutedJobsKey = key
        } catch is CancellationError {
            return
        } catch {
            cronNotificationsLogger.notice("Cron notifications not read: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Turns a job's notifications on or off. False when the host didn't
    /// take it (the switch then shows the host's value again) or another
    /// change is still in flight (the switch is disabled meanwhile).
    @discardableResult
    func setCronJobNotifies(_ notify: Bool, for job: CronJob) async -> Bool {
        guard supportsCronNotifications, cronNotificationsChangingJobID == nil else { return false }
        let profile = activeProfile
        let key = cronNotificationsKey(profile: profile)
        cronNotificationsChangingJobID = job.id
        defer { cronNotificationsChangingJobID = nil }
        // The switch moves at once; the host's answer settles it. Not read
        // yet: start from nothing muted, as the switch showed.
        if cronMutedJobsKey != key {
            cronMutedJobIDs = []
            cronMutedJobsKey = key
        }
        let wasMuted = cronMutedJobIDs.contains(job.id)
        if notify { cronMutedJobIDs.remove(job.id) } else { cronMutedJobIDs.insert(job.id) }
        do {
            let muted = try await cronNotificationsClient.setNotify(notify, jobID: job.id, profile: profile)
            guard key == cronNotificationsKey(profile: activeProfile) else { return false }
            cronMutedJobIDs = muted
            cronMutedJobsKey = key
            return true
        } catch {
            // Only this job goes back: a refresh may have replaced the rest.
            if cronMutedJobsKey == key {
                if wasMuted { cronMutedJobIDs.insert(job.id) } else { cronMutedJobIDs.remove(job.id) }
            }
            if error is CancellationError { return false }
            cronNotificationsLogger.notice("Cron notifications not saved: \(error.localizedDescription, privacy: .public)")
            errorMessage = AppLocalization.string("Could not change this job's notifications: \(UserFacingError.message(for: error))")
            return false
        }
    }
}
