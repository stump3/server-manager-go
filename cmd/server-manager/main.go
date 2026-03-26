package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/spf13/cobra"
	"github.com/stump3/server-manager/internal/app"
	"github.com/stump3/server-manager/internal/cli"
	"github.com/stump3/server-manager/internal/tui"
)

// version is set at build time via -ldflags "-X main.version=vYYYYMMDD".
var version = "dev"

func main() {
	// Root context — cancelled on SIGINT / SIGTERM.
	// Using cobra's PersistentPreRunE to propagate ctx into subcommands.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var configPath string

	// Bootstrap wrapper: initialise config + logger + container.
	// Deferred so --config flag is parsed before Bootstrap is called.
	var container *app.Container

	rootCmd := &cobra.Command{
		Use:   "server-manager",
		Short: "VPN server management: Remnawave Panel · MTProxy · Hysteria2",
		// No subcommand → launch interactive TUI
		RunE: func(cmd *cobra.Command, _ []string) error {
			if err := bootstrap(configPath, &container); err != nil {
				return err
			}
			return runTUI(ctx, container)
		},
		// Silence cobra's default error printing — we handle it ourselves.
		SilenceErrors: true,
		SilenceUsage:  true,
	}

	rootCmd.PersistentFlags().StringVar(&configPath, "config", "", "Path to config file (default: ~/.config/server-manager/config.yaml)")
	rootCmd.PersistentPreRunE = func(cmd *cobra.Command, _ []string) error {
		// Skip bootstrap for root (handled in RunE to avoid double init).
		if cmd.Use == rootCmd.Use {
			return nil
		}
		return bootstrap(configPath, &container)
	}

	// Attach all CLI subcommands. They receive &container (pointer so Bootstrap
	// sets it before subcommand RunE fires).
	for _, sub := range cli.Subcommands(&container) {
		rootCmd.AddCommand(sub)
	}

	rootCmd.SetContext(ctx)
	if err := rootCmd.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func bootstrap(configPath string, dst **app.Container) error {
	if *dst != nil {
		return nil // already initialised
	}
	c, _, err := app.Bootstrap(configPath)
	if err != nil {
		return fmt.Errorf("bootstrap: %w", err)
	}
	*dst = c
	return nil
}

func runTUI(ctx context.Context, c *app.Container) error {
	model := tui.NewMainMenu(ctx, c.HealthSvc, version)
	p := tea.NewProgram(model, tea.WithAltScreen())
	_, err := p.Run()
	return err
}
