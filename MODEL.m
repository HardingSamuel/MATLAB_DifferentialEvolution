classdef MODEL < handle
  properties
    names = struct('self','myModel','params','');
    
    data = table.empty();
    
    CHAINS = CHAIN.empty();
    
    fcn = {};
    
    settings = struct(...
      'n',...
      struct('steps',1000,'chains',3,'groups',1),...
      'sampling',...
      struct('pBurnin',0.25,'pMigrate',0.1,'pMutate',1),...
      'usePrevious',1)
    
    bayes = struct();
    
    store = struct('params',nan,'prediction',nan,'like',nan,'kept',nan);
    
  end
  methods
    function M = MODEL()
    end
    
    function init_model(M)
      M.settings.n.params = size(M.bayes.priors,1);
      M.settings.n.burnin = round(M.settings.sampling.pBurnin * M.settings.n.steps);
      % naming
      if strcmp(M.names.params,'')
        M.names.params = arrayfun(@(pp) ['\beta_{' num2str(pp) '}'],1:M.settings.n.params,'uni',0);
      end
    end
    
    function init_chains(M)
      G = M.calc_groups;
      % create empty arrays
      for cc = 1:M.settings.n.chains
        if ~M.settings.usePrevious || length(M.CHAINS) < cc
          % make the chain
          M.CHAINS(cc) = CHAIN();
          % insert the priors
          M.CHAINS(cc).priors = M.bayes.priors;
          % initialize values for parameters
          M.CHAINS(cc).reset_value;
          % define bounds for each parameter
          M.CHAINS(cc).calc_range
        else
        end
        
        % storage vectors
        M.CHAINS(cc).LIKE = nan(M.settings.n.steps,3);
        M.CHAINS(cc).PREDICTION = cell(M.settings.n.steps,1);
        M.CHAINS(cc).PARAMS = nan(M.settings.n.steps,M.settings.n.params);
        M.CHAINS(cc).KEPT = nan(M.settings.n.steps,1);
        
        % calculate the priors for the initial run
        M.CHAINS(cc).calc_prior
        
        % assign this chain to its group
        M.CHAINS(cc).group = G(cc);
        
        % set up the proposal distribution
        M.CHAINS(cc).prop.heatWindow = round(0.001 * M.settings.n.steps);
      end
    end
    
    function fit(M)
      M.init_model
      M.init_chains      
      
      tic
      for tt = 2:M.settings.n.steps
        % progress bar
        M.show_progress(tt)
        % update the chains
        PREV = M.prop_DE(tt);
        for cc = 1:M.settings.n.chains
          % temporary handle
          C = M.CHAINS(cc);
          % compute the prior with these values
          C.calc_prior
          % see how well these values predict the data
          C.calc_likelihood(M.fcn,M.data)
          % combine likelihood and prior
          C.calc_posterior;
          % do we accept these new values
          [M.CHAINS(cc),accept] = M.acceptReject(PREV(cc),C);
          
          % % % STORE % % %
          % store whether we accepted or not
          M.CHAINS(cc).KEPT(tt) = accept;
          % store the params of whichever was accepted
          M.CHAINS(cc).PARAMS(tt,:) = M.CHAINS(cc).params;
          % store the likelihoods
          M.CHAINS(cc).LIKE(tt,:) = [M.CHAINS(cc).logPrior,M.CHAINS(cc).logLike,M.CHAINS(cc).logPost];
          
          % % % ADJUST % % %
          % adjust the proposal distribution if necessary
          M.CHAINS(cc).prop_adjustSize(tt);
        end
      end
      M.predict
      M.collect_chains
      M.diag_post
      M.settings.runTime = toc;
      M.plot_all
    end
    
    function predict(M)
      for tt = 1:M.settings.n.steps
        % progress bar
        M.show_progress(tt)
        for cc = 1:M.settings.n.chains
          M.CHAINS(cc).calc_prediction(M.fcn,M.data);
          % store
          M.CHAINS(cc).PREDICTION{tt} = M.CHAINS(cc).prediction;
        end
      end
    end
    
    
    
    function collect_chains(M)
      % initialize arrays
      nC_nS = M.settings.n.chains * M.settings.n.steps;
      M.store.params = nan(nC_nS,size(M.CHAINS(1).PARAMS,2));
      M.store.like = nan(nC_nS,size(M.CHAINS(1).LIKE,2));
      M.store.kept = nan(nC_nS,size(M.CHAINS(1).KEPT,2));
      M.store.prediction = nan(nC_nS,size(M.CHAINS(1).PREDICTION{1},2));
      % loop through chains
      for cc = 1:M.settings.n.chains
        % indices
        ii(1) = M.settings.n.steps * (cc-1) + 1;
        ii(2) = ii(1) + M.settings.n.steps - 1;
        % concatenate
        M.store.params(ii(1):ii(2),:) = M.CHAINS(cc).PARAMS;
        M.store.like(ii(1):ii(2),:) = M.CHAINS(cc).LIKE;
        M.store.kept(ii(1):ii(2),:) = M.CHAINS(cc).KEPT;        
        M.store.prediction(ii(1):ii(2),:) = cat(1,M.CHAINS(cc).PREDICTION{:});
      end      
    end
    
    
    %%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%% PROPOSAL %%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % % % master % % %
    % coordinates the DE process across all chains
    function PREV = prop_DE(M,tt)
      % % % migrate % % %
      % select which groups should migrate
      doMigrate = rand <= M.settings.sampling.pMigrate;
      if doMigrate; M.prop_migrate; end
      PREV = copy(M.CHAINS);
      
      % % % mutation / crossover % % %
      doMutate = rand(1,M.settings.n.chains) <= M.settings.sampling.pMutate;
      mutateIndex = find(doMutate);
      M.prop_mutate(mutateIndex);
      
      crossIndex = find(~doMutate);
      M.prop_crossover(crossIndex,tt);
      
      
      % make sure all the new values are valid
      for cc = 1:M.settings.n.chains
        M.CHAINS(cc).calc_range;
        M.CHAINS(cc).calc_safeV;
      end
    end
    
    
    % % % mutate % % %
    function prop_mutate(M,I)
      for cc = 1:length(I)
        C = M.CHAINS(I(cc));
        for pp = 1:length(C.params)
          C.params(pp) = C.params(pp) + C.prop.sigma * randn();
        end
      end
    end
    
    % % % crossover % % %
    function prop_crossover(M,I,tt)
      G = cat(2,M.CHAINS.group);
      CTEMP = nan(M.settings.n.chains,M.settings.n.params);
      for cc = 1:length(I)
        % see Approximate Bayesian computation with differential evolution, page 4
        
        % % % get group association % % %
        C = M.CHAINS(I(cc));
        % what group is this chain in?
        myGroup = C.group;
        % which other chains are in this group
        groupChains = find(G == myGroup);
        % this chain ignores itself
        groupChains(groupChains == cc) = [];
        
        % % % sample a base particle with probability proportional to overall fit % % %
        % log posteriors of others in group
        p_thetaB = cat(2,M.CHAINS(groupChains).logPost);
        % compute the relative likelihood (in log space)
        relativeWeightsInLog = p_thetaB - min(p_thetaB);
        % convert to probability space
        relativeWeightsInP = exp(relativeWeightsInLog);
        % prevent any errors if one value far exceeds the others, set its
        % weight to be equal to the next highest
        if any(isinf(relativeWeightsInP))
          bestOther = max(relativeWeightsInP(~isinf(relativeWeightsInP)));
          relativeWeightsInP(isinf(relativeWeightsInP)) = bestOther;
        end
        % normalize
        totalP = sum(relativeWeightsInP);
        % prevent errors
        if isinf(totalP); totalP = bestOther; end
        normedWeights = relativeWeightsInP ./ totalP;
        normedWeights = normedWeights ./ sum(normedWeights);
        % select a random group member with probability proportional to its
        % log likelihood
        csWeights = cumsum(normedWeights);
        r = sum(rand > csWeights)+1;
        theta_B = groupChains(r);
        
        % % % sample two other reference particles % % %
        % don't resample the base particle from above
        groupChains(groupChains == theta_B) = [];
        % grab a 2nd particle randomly for the first reference
        theta_M = groupChains(randi(length(groupChains)));
        % don't sample it again
        groupChains(groupChains == theta_M) = [];
        % grab a 3rd particle randomly for the second reference
        theta_N = groupChains(randi(length(groupChains)));
        
        % % % compute the distance % % %
        % distance between references
        refDist = M.CHAINS(theta_M).params - M.CHAINS(theta_N).params;
        % distance to base from self
        baseDist = M.CHAINS(theta_B).params - C.params;
        
        % % % scaling values % % %
        gamma1 = .5 + (.5 * rand(1,M.settings.n.params));
        % two modes of sampling
        if tt <= M.settings.n.burnin
          gamma2 = 0.5 + (0.5 * rand);
        else
          gamma2 = 0;
        end
        b = (.002 * rand) - .001;
        
        CTEMP(cc,:) = gamma1.*(refDist) + gamma2*(baseDist) + b;
        
      end
      
    end
    
    % % % migrate % % %
    function prop_migrate(M)
      % loop through each group
      G = cat(2,M.CHAINS.group);
      LP = cat(2,M.CHAINS.logPost);
      B = nan(1,M.settings.n.groups);
      for gg = 1:M.settings.n.groups
        % the chains in this group
        groupChains = find(G == gg);
        % log posteriors for the chains in thie group
        groupLogPost = LP(groupChains);
        % find the best chain in this group
        [~,bestChain] = max(groupLogPost);
        % make sure we only have one
        if length(bestChain) > 1; bestChain = bestChain(1); end
        % store it
        B(gg) = groupChains(bestChain);
      end
      
      % % % loop through each group and cycle the best % % %
      availGroups = 1:M.settings.n.groups;
      for gg = 1:M.settings.n.groups
        newGroup = availGroups(randi(length(availGroups)));
        M.CHAINS(B(gg)).group = newGroup;
        availGroups(availGroups == newGroup) = [];
      end
      [y,x] = hist(cat(2,M.CHAINS.group),1:M.settings.n.groups);
      if ~all(y == M.settings.n.chainsPerGroup)
        keyboard
      end
    end
    
    
    
    %%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%% PLOTTING %%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    
    % % % plot all % % %
    function plot_all(M)
      f201 = figure(201);clf
      f201.Name = [M.names.self '_fitting'];
      smh_exportFigButton(f201,[filesep M.names.self filesep]);
      paramAx = M.plot_params;
      M.plot_like;
      M.plot_kept;
      M.hist_params(paramAx);
    end
    
    % % % plot params % % %
    function ax = plot_params(M)
      % open the figure
      ax = subplot(1,3,1);
      cla; hold on
      % plot the parameters over time
      for pp = 1:M.settings.n.params
        plot(M.store.params(:,pp))
      end
      M.shade_burnin(gca);
    end
    
    % % % plot likelihoods % % %
    function ax = plot_like(M)
      ax = subplot(1,3,2);
      cla; hold on
      semilogy(M.store.like)
      hold on
      M.shade_burnin(gca);
    end
    
    % % % plot kept % % %
    function ax = plot_kept(M)
      ax = subplot(1,3,3);
      cla; hold on
      plot(conv(M.store.kept,(1/50)*ones(1,50),'valid'))
      ylim([0 1])
      M.shade_burnin(gca);
    end
    
    % % % histogram of features during burnin % % %
    function hist_params(M,varargin)
      % go off and run a separate function, rather than including all code
      % here
      vis_posteriors(M,varargin)
    end
    
    % % % select burn-in % % %
    function dOut = select_burnin(M,dIn)
      bInd = [];
      I = M.calc_burnIndices;
      for cc = 1:M.settings.n.chains
        bInd = [bInd,I(1,cc):I(2,cc)];
      end
      dOut = dIn;
      dOut(bInd,:) = [];
    end
    
    % % % shade burn-in % % %
    function shade_burnin(M,ax)
      I = M.calc_burnIndices;
      Y = ax.YLim;
      for cc = 1:M.settings.n.chains
        area(I([1 1 2 2],cc)',Y([1 2 2 1]),Y(1),...
          'FaceColor',[0 0 0],'FaceAlpha',0.05,...
          'EdgeAlpha',0)
      end
    end
    
    %%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%% CALCULATE %%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % % % burnin indices % % %
    function I = calc_burnIndices(M)
      I = round(M.settings.n.burnin):...
        M.settings.n.steps:(M.settings.n.steps * M.settings.n.chains);
      I = [[(1:M.settings.n.chains)-1] * M.settings.n.steps;I];
      I(1,:) = I(1,:) + 1;
    end
    
    % % % group assignments % % %
    function G = calc_groups(M)
      % assign chains to groups for crossover/migration
      % % crossover works only if there are 4 or more chains
      if M.settings.n.chains >= 4
        M.settings.n.chainsPerGroup = M.settings.n.chains / M.settings.n.groups;
        % if dividing the chains into this many groups leaves at least 4
        % per group, then go ahead and divide them
        if M.settings.n.chainsPerGroup >= 4
          % divide them into groups
          G = ceil(randperm(M.settings.n.chains,M.settings.n.chains) / M.settings.n.chainsPerGroup);
          % if the chains are set to mutate 100% of the time, then
          % crossover is worthless. If that's the case, update the pMutate
          % to be 0.5 instead
          if M.settings.sampling.pMutate == 1
            M.settings.sampling.pMutate = 0.5;
          end
          
        else
          % otherwise force just one group
          M.settings.n.groups = 1;
          M.settings.n.chainsPerGroup = M.settings.n.chains;
          M.settings.sampling.pMigrate = 0;
          M.settings.sampling.pMutate = 1;
          G = ones(1,M.settings.n.chains);
        end
        
        
      else
        % otherwise force just one group
        M.settings.n.groups = 1;
        M.settings.n.chainsPerGroup = M.settings.n.chains;
        M.settings.sampling.pMigrate = 0;
        M.settings.sampling.pMutate = 1;
        G = ones(1,M.settings.n.chains);
      end
    end
    
    
    %%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%% DIAGNOSTICS %%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % % % compute information about the posterior distribution % % %
    function diag_post(M)
      for pp = 1:M.settings.n.params
        burnParamVals = M.select_burnin(M.store.params(:,pp));
        M.bayes.posteriors.parameters(pp) = M.calc_HDI(burnParamVals);
      end
    end
    
    %%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%% MISC %%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % % % progress bar % % %
    function show_progress(M,tt)
      percent1 = max(1,round(.01*M.settings.n.steps));
      if tt == 1
        progressbar(M.names.self)
      end
      
      if ~rem(tt,percent1)
        progressbar(tt/M.settings.n.steps);
      end
    end
    
    
  end
  
  methods (Static)
    
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%% COMPUTE %%%%%%%%%%%%%%%%%%%%%%%%%
    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
    % % % compute the log likelihood % % %
    % converts probabilities to log probabilities, after checking to make
    % sure the values are within 0-1
    function safeLL = calc_safeLL(P)
      safeLike = min(max(1e-20,P),1);
      logSafeLike = log(safeLike);
      safeLL = sum(logSafeLike);
    end
    
    % % % do we use the proporsed parameters? s% % %
    function [NEW,accept] = acceptReject(PREV,PROP)
      accept = MODEL.calc_accept(PREV,PROP);
      if accept
        NEW = PROP;
      else
        NEW = PREV;
      end
    end
    
    function accept = calc_accept(PREV,PROP)
      if isnan(PREV.logPost)
        accept = 1;
      else
        logRatio = PROP.logPost - PREV.logPost;
        r = log(rand());
        accept = r <= logRatio;
      end
    end
    
    
    % % % diagnostics % % %
    function fit = calc_HDI(values)
      [fit.mu,fit.sig] = normfit(values);
      fit.HDIedges = norminv([.025 .975],fit.mu,fit.sig);
      fit.plotEdges = norminv([.001 .999],fit.mu,fit.sig);
      %
      fit.mode = mode(round(values,2));
      fit.values = values;
    end
    
  end
  
end