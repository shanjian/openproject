import { ComponentFixture, TestBed } from '@angular/core/testing';
import { By } from "@angular/platform-browser";
import { provideHttpClient, withInterceptorsFromDi } from '@angular/common/http';
import { HttpTestingController, provideHttpClientTesting } from '@angular/common/http/testing';
import { GitActionsMenuComponent } from "./git-actions-menu.component";
import { GitActionsService } from "../git-actions/git-actions.service";
import { I18nService } from "core-app/core/i18n/i18n.service";
import { OpContextMenuLocalsToken } from "core-app/shared/components/op-context-menu/op-context-menu.types";
import { ApiV3Service } from 'core-app/core/apiv3/api-v3.service';
import { ToastService } from 'core-app/shared/components/toaster/toast.service';

describe('GitActionsMenuComponent', () => {
  let component:GitActionsMenuComponent;
  let fixture:ComponentFixture<GitActionsMenuComponent>;
  let gitActionsService:jasmine.SpyObj<GitActionsService>;
  let toastService:jasmine.SpyObj<ToastService>;
  let httpTesting:HttpTestingController;

  const I18nServiceStub = {
    t: function(key:string) {
      return key;
    }
  };
  const localsStub = {
    workPackage: { id: '76954' },
    items: [],
  };
  const apiV3ServiceStub = {
    work_packages: {
      id: () => ({ path: '/api/v3/work_packages/76954' }),
    },
  };
  const branchTargetsPath = '/api/v3/work_packages/76954/gitlab/branch_targets';

  beforeEach(async () => {
    const gitActionsServiceSpy = jasmine.createSpyObj('GitActionsService', [
      'timestampSuffix', 'branchName', 'mergeRequestMessage', 'mergeRequestMessageDisplayText', 'gitCommand',
    ]);
    gitActionsServiceSpy.timestampSuffix.and.returnValue('0809-1430');
    gitActionsServiceSpy.branchName.and.returnValue('story/76954-eet-review-and-deploy-retail-store-0809-1430');
    gitActionsServiceSpy.mergeRequestMessage.and.returnValue('[OP#76954](http://example.com/work_packages/76954) title');
    gitActionsServiceSpy.mergeRequestMessageDisplayText.and.returnValue('[OP#76954](http://example.com/work_packages/76954) title');
    gitActionsServiceSpy.gitCommand.and.returnValue("git checkout -b 'story/76954-eet-review-and-deploy-retail-store-0809-1430' && git commit --allow-empty -m 'OP#76954 title'");

    const toastServiceSpy = jasmine.createSpyObj('ToastService', ['addSuccess', 'addError']);

    await TestBed
      .configureTestingModule({
        declarations: [
          GitActionsMenuComponent,
        ],
        providers: [
          { provide: I18nService, useValue: I18nServiceStub },
          { provide: OpContextMenuLocalsToken, useValue: localsStub },
          { provide: GitActionsService, useValue: gitActionsServiceSpy },
          { provide: ApiV3Service, useValue: apiV3ServiceStub },
          { provide: ToastService, useValue: toastServiceSpy },
          provideHttpClient(withInterceptorsFromDi()),
          provideHttpClientTesting(),
        ],
      })
      .compileComponents();
  });

  beforeEach(() => {
    fixture = TestBed.createComponent(GitActionsMenuComponent);
    component = fixture.componentInstance;
    gitActionsService = TestBed.inject(GitActionsService) as jasmine.SpyObj<GitActionsService>;
    toastService = TestBed.inject(ToastService) as jasmine.SpyObj<ToastService>;
    httpTesting = TestBed.inject(HttpTestingController);

    fixture.detectChanges();

    httpTesting.expectOne(branchTargetsPath).flush({ targets: [] });
  });

  afterEach(() => {
    httpTesting.verify();
  });

  it('should create', () => {
    expect(component).toBeTruthy();
  });

  it('computes the timestamp suffix and the branch name exactly once, in the constructor', () => {
    expect(gitActionsService.timestampSuffix).toHaveBeenCalledTimes(1);
    expect(gitActionsService.branchName).toHaveBeenCalledTimes(1);
    expect(gitActionsService.branchName).toHaveBeenCalledWith(component.workPackage, '0809-1430');
  });

  it('reuses the same cached branch name for the branch snippet and the git command snippet', () => {
    const [branchSnippet, , commandSnippet] = component.snippets;

    expect(branchSnippet.textToDisplay()).toEqual('story/76954-eet-review-and-deploy-retail-store-0809-1430');
    expect(branchSnippet.textToCopy()).toEqual('story/76954-eet-review-and-deploy-retail-store-0809-1430');
    expect(gitActionsService.gitCommand).toHaveBeenCalledWith(component.workPackage, '0809-1430');
    expect(commandSnippet.textToDisplay()).toContain('story/76954-eet-review-and-deploy-retail-store-0809-1430');
  });

  it('labels the message row as the merge request message and uses the Markdown-linked text', () => {
    const [, messageSnippet] = component.snippets;

    expect(messageSnippet.name).toEqual('js.gitlab_integration.tab_header_mr.git_actions.merge_request_message');
    expect(messageSnippet.textToCopy()).toEqual('[OP#76954](http://example.com/work_packages/76954) title');
  });

  it('should generate the branch name on copy button click', () => {
    const copyButton = fixture.debugElement.query(By.css('.copy-button')).nativeElement;

    copyButton.click();
    fixture.detectChanges();

    expect(component.copiedSnippetId).toEqual('branch');
  });

  it('sends the cached branch name (not a freshly computed one) when creating a branch', () => {
    component.createBranch();

    const req = httpTesting.expectOne('/api/v3/work_packages/76954/gitlab/branches');
    expect(req.request.body).toEqual({ branchName: 'story/76954-eet-review-and-deploy-retail-store-0809-1430' });
    req.flush({ branch: 'story/76954-eet-review-and-deploy-retail-store-0809-1430', webUrl: null, alreadyExisted: false, repository: 'Backend' });

    expect(toastService.addSuccess).toHaveBeenCalled();
  });

  it('includes the mapping id alongside the cached branch name when creating a branch for a specific target', () => {
    component.createBranch({ id: 7, name: 'Backend', gitlabProjectId: '42' });

    const req = httpTesting.expectOne('/api/v3/work_packages/76954/gitlab/branches');
    expect(req.request.body).toEqual({
      mappingId: 7,
      branchName: 'story/76954-eet-review-and-deploy-retail-store-0809-1430',
    });
    req.flush({ branch: 'story/76954-eet-review-and-deploy-retail-store-0809-1430', webUrl: null, alreadyExisted: false, repository: 'Backend' });
  });
});
