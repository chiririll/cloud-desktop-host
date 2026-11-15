/*
 * cloud-desktop-host — session.h
 * `cloud-desktop-host --kde-shutdown <action>`: org.kde.Shutdown for Plasma's Log out / Restart / Shut down.
 */
#ifndef CD_SESSION_H
#define CD_SESSION_H

/* One-shot D-Bus activated service: owns org.kde.Shutdown, runs `<action> logout|reboot|shutdown`
 * for the first call, exits. Returns the process exit code. */
int cd_kde_shutdown_main(const char *action);

#endif /* CD_SESSION_H */
