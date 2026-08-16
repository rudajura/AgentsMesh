package repositoryconnect

import (
	"context"
	"errors"

	"connectrpc.com/connect"

	"github.com/anthropics/agentsmesh/backend/internal/api/connect/interceptors"
	"github.com/anthropics/agentsmesh/backend/internal/middleware"
	repositoryservice "github.com/anthropics/agentsmesh/backend/internal/service/repository"
	"github.com/anthropics/agentsmesh/backend/pkg/policy"
	repositoryv1 "github.com/anthropics/agentsmesh/proto/gen/go/repository/v1"
)

// ListRepositoryBranches mirrors REST handler `ListBranches`
// (repositories_branches.go:54). Access token comes from the request body
// because Connect has no query-string surface.
func (s *Server) ListRepositoryBranches(
	ctx context.Context, req *connect.Request[repositoryv1.ListRepositoryBranchesRequest],
) (*connect.Response[repositoryv1.ListRepositoryBranchesResponse], error) {
	ctx, _, err := interceptors.ResolveOrgScope(ctx, req.Msg, s.orgSvc)
	if err != nil {
		return nil, err
	}
	if err := s.requireRepoRead(ctx, req.Msg.GetId()); err != nil {
		return nil, err
	}
	if req.Msg.GetAccessToken() == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("access token required"))
	}

	branches, err := s.repoSvc.ListBranches(ctx, req.Msg.GetId(), req.Msg.GetAccessToken())
	if err != nil {
		return nil, mapServiceError(err)
	}
	items := make([]*repositoryv1.Branch, 0, len(branches))
	for _, name := range branches {
		items = append(items, &repositoryv1.Branch{Name: name})
	}
	return connect.NewResponse(&repositoryv1.ListRepositoryBranchesResponse{
		Items: items,
		Total: int64(len(items)),
	}), nil
}

// SyncRepositoryBranches mirrors REST handler `SyncBranches`
// (repositories_branches.go:15). Body shape is identical to ListBranches
// — REST distinguishes via verb / path, Connect via method name.
func (s *Server) SyncRepositoryBranches(
	ctx context.Context, req *connect.Request[repositoryv1.SyncRepositoryBranchesRequest],
) (*connect.Response[repositoryv1.ListRepositoryBranchesResponse], error) {
	ctx, _, err := interceptors.ResolveOrgScope(ctx, req.Msg, s.orgSvc)
	if err != nil {
		return nil, err
	}
	if err := s.requireRepoRead(ctx, req.Msg.GetId()); err != nil {
		return nil, err
	}
	if req.Msg.GetAccessToken() == "" {
		return nil, connect.NewError(connect.CodeInvalidArgument, errors.New("access token required"))
	}

	branches, err := s.repoSvc.ListBranches(ctx, req.Msg.GetId(), req.Msg.GetAccessToken())
	if err != nil {
		return nil, mapServiceError(err)
	}
	items := make([]*repositoryv1.Branch, 0, len(branches))
	for _, name := range branches {
		items = append(items, &repositoryv1.Branch{Name: name})
	}
	return connect.NewResponse(&repositoryv1.ListRepositoryBranchesResponse{
		Items: items,
		Total: int64(len(items)),
	}), nil
}

// ListRepositoryMergeRequests mirrors REST handler `ListRepositoryMergeRequests`
// (repositories_merge_requests.go:18). Defaults state="all" when absent.
//
// The DB rows this normally reads only exist once a webhook has delivered at
// least one event, which never happens for repos whose webhook can't reach us
// (e.g. local dev behind localhost). So when a branch is given, we first try
// a live fetch from the git provider on the caller's behalf and, only if that
// fails (no connected token, provider error, ...), fall back to the DB read.
func (s *Server) ListRepositoryMergeRequests(
	ctx context.Context, req *connect.Request[repositoryv1.ListRepositoryMergeRequestsRequest],
) (*connect.Response[repositoryv1.ListRepositoryMergeRequestsResponse], error) {
	ctx, _, err := interceptors.ResolveOrgScope(ctx, req.Msg, s.orgSvc)
	if err != nil {
		return nil, err
	}
	if err := s.requireRepoRead(ctx, req.Msg.GetId()); err != nil {
		return nil, err
	}

	state := req.Msg.GetState()
	if state == "" {
		state = "all"
	}
	branch := req.Msg.GetBranch()

	if branch != "" {
		if items, err := s.liveMergeRequests(ctx, req.Msg.GetId(), branch, state); err == nil {
			return connect.NewResponse(&repositoryv1.ListRepositoryMergeRequestsResponse{
				Items: items,
				Total: int64(len(items)),
			}), nil
		}
	}

	mrs, err := s.repoSvc.ListMergeRequests(ctx, req.Msg.GetId(), branch, state)
	if err != nil {
		return nil, connect.NewError(connect.CodeInternal, err)
	}
	items := make([]*repositoryv1.MergeRequest, 0, len(mrs))
	for _, mr := range mrs {
		items = append(items, toProtoMergeRequest(mr))
	}
	return connect.NewResponse(&repositoryv1.ListRepositoryMergeRequestsResponse{
		Items: items,
		Total: int64(len(items)),
	}), nil
}

func (s *Server) liveMergeRequests(ctx context.Context, repoID int64, branch, state string) ([]*repositoryv1.MergeRequest, error) {
	webhookSvc := s.repoSvc.GetWebhookService()
	if webhookSvc == nil {
		return nil, errors.New("webhook service not configured")
	}
	repo, err := s.repoSvc.GetByID(ctx, repoID)
	if err != nil {
		return nil, err
	}
	gitMRs, err := webhookSvc.ListMergeRequestsLive(ctx, repo, middleware.GetTenant(ctx).UserID, branch, state)
	if err != nil {
		return nil, err
	}
	items := make([]*repositoryv1.MergeRequest, 0, len(gitMRs))
	for _, mr := range gitMRs {
		items = append(items, toProtoMergeRequest(repositoryservice.FromGitMergeRequest(mr)))
	}
	return items, nil
}

// requireRepoRead checks the read policy for a repository — used by the
// branch + merge-request endpoints which all gate on AllowRead.
func (s *Server) requireRepoRead(ctx context.Context, repoID int64) error {
	repo, err := s.repoSvc.GetByID(ctx, repoID)
	if err != nil {
		return mapServiceError(err)
	}
	tenant := middleware.GetTenant(ctx)
	sub := policy.NewSubject(tenant.OrganizationID, tenant.UserID, tenant.UserRole)
	if !policy.RepositoryPolicy.AllowRead(sub, s.resourceWithGrants(
		ctx, repo.ID, repo.OrganizationID, repo.ImportedByUserID, repo.Visibility,
	)) {
		return connect.NewError(connect.CodePermissionDenied, errors.New("access denied"))
	}
	return nil
}
