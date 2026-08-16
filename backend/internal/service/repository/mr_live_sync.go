package repository

import (
	"context"

	"github.com/anthropics/agentsmesh/backend/internal/domain/gitprovider"
	"github.com/anthropics/agentsmesh/backend/internal/infra/git"
)

// ListMergeRequestsLive fetches merge/pull requests directly from the git
// provider API on behalf of userID. Unlike ListMergeRequests (DB read), this
// doesn't depend on webhook events ever having reached us — it's the fallback
// path for environments where the provider can't call back into our webhook
// endpoint (e.g. local dev behind localhost).
func (s *WebhookService) ListMergeRequestsLive(ctx context.Context, repo *gitprovider.Repository, userID int64, branch, state string) ([]*git.MergeRequest, error) {
	provider, err := s.getGitProviderForUser(ctx, repo, userID)
	if err != nil {
		return nil, err
	}
	if branch != "" {
		return provider.ListMergeRequestsByBranch(ctx, repo.ExternalID, branch, state)
	}
	return provider.ListMergeRequests(ctx, repo.ExternalID, state, 1, 50)
}

// FromGitMergeRequest adapts a live provider response onto the same shape
// ListMergeRequests (DB read) returns, so callers can render both without a
// branch in the response type.
func FromGitMergeRequest(mr *git.MergeRequest) *MergeRequestInfo {
	return &MergeRequestInfo{
		ID:           int64(mr.ID),
		MRIID:        mr.IID,
		Title:        mr.Title,
		State:        mr.State,
		MRURL:        mr.WebURL,
		SourceBranch: mr.SourceBranch,
		TargetBranch: mr.TargetBranch,
	}
}
