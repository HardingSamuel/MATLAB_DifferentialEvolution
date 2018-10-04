classdef CHAIN < matlab.mixin.Copyable
  properties (SetObservable)
    
    % current paramaters
    params = nan;
    % predicted
    prediction = nan;
    % priors for each parameter
    priors = cell(0,5);
    % allowed range for parameters to visit
    range = nan(0,2);
    % group number
    group = nan;
    
    % proposal properties
    prop = struct('heatWindow',50,'momentum',.01,'sigma',1);
    
    % store log probabilities
    logPrior = nan;
    logLike = nan;
    logPost = nan;
    
    % store across time
    PARAMS = nan();
    PREDICTION = cell(0,1);
    LIKE = nan();
    KEPT = nan();
    
    
  end
  methods
    
    function C = CHAIN
      % % % add listeners % % %
      %       addlistener(C,'priors','PostSet',@C.reset_value);
      %       addlistener(C,'priors','PostSet',@C.calc_range);
    end
    
    %% CALC
    % % % PRIOR % % %
    function calc_prior(C,~,~)
      LP = 0;
      for pp = 1:size(C.priors,1)
        C.update_hier(pp);
        LP = LP + CHAIN.update_prior(C.params(pp),C.priors(pp,:));
      end
      C.logPrior = LP;
    end
    
    % % % LIKELIHOOD % % %
    function calc_likelihood(C,F,D)
      C.logLike = F{1}('fit',C.params,D);
    end
    
    % % % POSTERIOR % % %
    function calc_posterior(C)
      C.logPost = C.logPrior + C.logLike;
    end
    
    % % % PREDICTIONS % % %
    function calc_prediction(C,F,D)
      C.prediction = F{1}('pred',C.params,D);
    end
    
    function calc_range(C,~,~)
      % Calculate the acceptable range that this parameter value can take
      % on without being out of bounds
      for pp = 1:size(C.priors,1)
        C.update_hier(pp);
        P = C.priors(pp,:);
        C.range(pp,:) = icdf(P{1},[1e-10,1-(1e-10)],P{2},P{3});
      end
    end
    
    function calc_safeV(C)
      % Makes sure the value for a given parameter is within its allowed
      % range
      for pp = 1:size(C.priors,1)
        if C.params(pp) < C.range(pp,1) || C.params(pp) > C.range(pp,2)
          C.params(pp) = max(C.range(pp,1),min(C.range(pp,2),C.params(pp)));
        end
      end
    end
    
    function reset_value(C,~,~)
      % reset the parameter's current value to the 50th percentile of its prior distribution.      
      for pp = 1:size(C.priors,1)
        C.update_hier(pp);
        P = C.priors(pp,:);
        C.params(pp) = icdf(P{1},0.5,P{2},P{3});
      end
    end
    
    
    % % % adjust the proposal size % % %
    function prop_adjustSize(C,tt)
      if tt >= C.prop.heatWindow
        timesVec = tt - C.prop.heatWindow + 1:tt;
        proportionKept = mean(C.KEPT(timesVec));
        acceptMinus234 = proportionKept - 0.234;
        newScale = logistic(acceptMinus234,C.prop.momentum)+.5;
        newVar = max(1e-10,min(1e-1,newScale .* C.prop.sigma));
        C.prop.sigma = newVar;
      else
        % leave it as is
      end
    end
    
    % % % extract priors % % %
    % returns the values of the prior distribution for a given parameter
    % % allows these to be hierarchical
    function update_hier(C,pp)
      if CHAIN.isHier(C.priors(pp,:))
        hier_params(C,pp)
      end
    end
    
    function hier_params(C,pp)      
      if ~isempty(C.priors{pp,4})
        C.priors{pp,2} = C.params(C.priors{pp,4});
      end
      if ~isempty(C.priors{pp,5})
        C.priors{pp,3} = C.params(C.priors{pp,5});
      end      
    end
  end
  methods (Static)
    
    function LL = update_prior(V,P)
      % Calculate the (log) prior probability of the parameter's current value, given its prior distribution.
      LL = MODEL.calc_safeLL(pdf(P{1},V,P{2},P{3}));
    end
    
    function isH = isHier(P)
      if ~isempty(P{4}) || ~isempty(P{5})
        isH = 1;
      else
        isH = 0;
      end
    end
    
  end
end
