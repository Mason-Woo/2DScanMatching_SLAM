function [res,assoc,P_r_index,P_n_index] = mahaAssociation(n,r,Opt,motion)
% Function mahaAssociation
% Computes correspondences between two scans
% In:
%           R: cart[2xN], P[2x2xN], points and uncertainty
%           N: cart[2xN], P[2x2xN], points and uncertainty
%           OPT: options and plot data
%           MOTION: [x y yaw], motion estimation 
%                   P[3x3] scan uncertainty
% Out:
%           RES: estimated error
%           ASSOC: association object


% which method to use? nearest neighbour(0) or virtual point(1)
PARAM.sm.estep_method = 0;
PARAM.debug = 0;

% Mahalanobis distance confidence
confidence = 0.90;
chi2value = chi2inv(confidence,2);

% Motion estimation

yaw =  motion.estimation(3);
siny = sin(yaw);
cosy = cos(yaw);

% Jacobian of the motion
%Jp = [-cosy siny; -siny -cosy];
Jp = [cosy -siny; siny cosy]; % MODIFICATO

% Apply motion estimation
[Bnf Bf Af aixs bixs] = transPolarCartScan(n, r, motion.estimation(3), motion.estimation(1:2), 2, Opt.scanmatcher.Br(2));
Bnf.cart(3,:) = 0; % Delete 1's from normalized 2D point
Bf.cart(3,:) =  0;

if Opt.scanmatcher.projfilter
    %c = Bf.cart(1:2,:);
    
    if ~isempty(bixs )
        n.P(:,:,bixs) = [];
        n.cart(:,bixs) = [];
    end
    
    if ~isempty(aixs )
        r.P(:,:,aixs) = [];
        r.cart = Af.cart;
    end
    
    c = Bf.cart(1:2,:);
else
    c = Bnf.cart(1:2,:);
    %r.cart = Al;
end

if isempty(n.cart) || isempty(r.cart)
    assoc = [];
    res = [];
    return
end

global DEBUG
if DEBUG.mahaAssociation || DEBUG.all

    set(Opt.plot_r,'XData',r.cart(1,:),'YData',r.cart(2,:));
    set(Opt.plot_n,'XData',c(1,:),'YData',c(2,:));
    drawnow
end

% Jacobian of both scans
j = 1:size(n.cart,2);
col3_tmp = [n.cart(1,j)*siny+n.cart(2,j)*cosy; -n.cart(1,j)*cosy+n.cart(2,j)*siny];
col3 = reshape(col3_tmp,2,1,size(n.cart,2));
diagonal = repmat(diag(-ones(1,2)),[1,1,size(n.cart,2)]);
Jq = [diagonal col3];

% Buffers initialization
a = zeros(2,size(n.cart,2)); % a buffer
Pe = zeros(2,2,size(n.cart,2)); % Pe buffer
indexBuffer = zeros(1,size(n.cart,2)); 
Pc_j = zeros(2,2,size(n.cart,2)); %Pc buffer

for j = 1:size(n.cart,2)
   
    
    Pc_j(:,:,j) = Jq(:,:,j)*motion.P*Jq(:,:,j)'+ Jp*n.P(:,:,j)*Jp';

    
    % draw_ellipse(c(:,j)',Pc_j(:,:,j),'b');
    i = 1:size(r.cart,2);
    d = [r.cart(1,i)-c(1,j); r.cart(2,i)-c(2,j)];
       
    % Covariances of r and q-p composition
    Pe_ij = [r.P(1,1,i)+Pc_j(1,1,j) r.P(1,2,i)+Pc_j(1,2,j); r.P(2,1,i)+Pc_j(2,1,j) r.P(2,2,i)+Pc_j(2,2,j)];
    
    % inv(Pe_ij) for a 2x2xn matrix. Each matrix must be [a b;b d] form
    det_Pe_ij = (Pe_ij(1,1,i).*Pe_ij(2,2,i)-Pe_ij(1,2,i).^2);
    inv_Pe_ij = [Pe_ij(2,2,i)./det_Pe_ij(1,1,i) -Pe_ij(1,2,i)./det_Pe_ij(1,1,i);-Pe_ij(1,2,i)./det_Pe_ij(1,1,i) Pe_ij(1,1,i)./det_Pe_ij(1,1,i)];
        
    inv_11 = squeeze(inv_Pe_ij(1,1,i))';
    inv_12 = squeeze(inv_Pe_ij(1,2,i))';
    inv_22 = squeeze(inv_Pe_ij(2,2,i))';

    % Mahalanobis distance
    dist = (d(1,i).^2).*inv_11+2.*d(1,i).*d(2,i).*inv_12 + (d(2,i).^2).*inv_22;

    if PARAM.sm.estep_method == 0 % ICNN
        [d_value,d_index] = min(dist);
       
        if(d_value <= chi2value)
            a_j = r.cart(:,d_index);
            Pa_j = Pe_ij(:,:,d_index);
            Pe(:,:,j) = Pa_j + Pc_j(:,:,j);

            % save a_j & Pa_j
            a(:,j) = a_j;
            Pe(:,:,j) = Pa_j + Pc_j(:,:,j);
            
            indexBuffer(1,j) = 1;
%             if DEBUG.mahaAssociation || DEBUG.all
%                 plot( [c(1,j) a_j(1) ],[c(2,j) a_j(2) ], 'm' )
%             end            
        end
    elseif PARAM.sm.estep_method == 1 % Virtual point
        d_index = dist<=chi2value;
        A = r.cart(:,d_index);

        Pe_ij = Pe_ij(:,:,d_index); 

        % Build association struct
        if (size(A,2) > 0)
            i = 1:size(A,2);

            % prob_a using multivariate normal pdf
            prob_a = mvnpdf(A',c(1:2,j)',Pe_ij);
            prob_a = prob_a';

            eta = 1/sum(prob_a,2);
            prob_a = eta*prob_a;

            % a_j
            a_j = sum(A.*[prob_a;prob_a],2);

            % Pa_j
            err = [A(1,i)-a_j(1); A(2,i)-a_j(2)];
            err = reshape(err,2,1,size(A,2));
            errQuad = [err(1,1,i).^2 err(1,1,i).*err(2,1,i); err(2,1,i).*err(1,1,i) err(2,1,i).^2]; % error in 2x2 matrix

            prob_a = reshape(prob_a,[1,1,size(A,2)]);
            errQuad(:,:,i) = errQuad(:,:,i).*[prob_a(:,:,i) prob_a(:,:,i); prob_a(:,:,i) prob_a(:,:,i)];

            Pa_j = sum(errQuad(:,:,i),3);

            % save a_j & Pa_j
            a(:,j) = a_j;
            Pe(:,:,j) = Pa_j + Pc_j(:,:,j);

            indexBuffer(1,j) = 1;
            
%             if DEBUG.mahaAssociation || DEBUG.all
%                 plot( [c(1,j) a_j(1) ],[c(2,j) a_j(2) ], 'm' )
%             end    
                    
            % Debug mode 3
            if PARAM.debug >= 3
                if assoc_index == PARAM.assoc_plot_interval
                    lines_assoc_scanK = repmat([NaN;NaN],1,size(A,2)*3);
                    a_rep = repmat(a(:,j),1,size(A,2));
                    k = 1:3:size(A,2)*3;
                    m = 1:size(A,2);
                    %pause;
                    lines_assoc_scanK(:,k) = a_rep(:,m);
                    lines_assoc_scanK(:,k+1) = A(:,m);
                    lines_a = [lines lines_assoc_scanK];
                    %pause;
                    %set(handle_assoc_scanK,'XData',lines_assoc_scanK(1,:),
                    %'YData',lines_assoc_scanK(2,:));

                    P_r_index = P_r_index + d_index;
                    P_n_index = [P_n_index j];

                    assoc_index = 1;
                else
                    assoc_index = assoc_index + 1;
                end
            end        
        end
    end
end

index = find(indexBuffer == 1);


% Keep only the associaton necessary values
assoc.oldn = n.cart(1:2,index);
assoc.new = c(:,index)';
assoc.ref = a(:,index)';
assoc.Pe = Pe(:,:,index);
assoc.Jq = Jq(:,:,index);
dd = assoc.new - assoc.ref;
res = sum( sqrt(dd(:,1).^2 + dd(:,2).^2) );
P_r_index = index;
